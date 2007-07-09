%%%----------------------------------------------------------------------
%%% File    : mod_multicast.erl
%%% Author  : Badlop <badlop@ono.com>
%%% Purpose : Extended Stanza Addressing (XEP-0033) support
%%% Created : 29 May 2007 by Badlop <badlop@ono.com>
%%% Id      : $Id$
%%%----------------------------------------------------------------------

-module(mod_multicast).
-author('badlop@ono.com').
-vsn('$Revision$').

-behaviour(gen_server).
-behaviour(gen_mod).

%% API
-export([start_link/2, start/2, stop/1]).

%% gen_server callbacks
-export([init/1,
	 handle_info/2,
	 handle_call/3,
	 handle_cast/2,
	 terminate/2,
	 code_change/3
	]).

-export([
	 route_packet_multicast/4,
	 do_route4/5,
	 purge_loop/1
	]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-record(state, {lserver, lservice, access, max_receivers}).

-record(multicastc, {rserver, response, ts}).
%% ts: timestamp (in seconds) when the cache item was last updated

-define(VERSION_MULTICAST, "$Revision$").
-define(PROCNAME, ejabberd_mod_multicast).

%% TODO: move this line to jlib.hrl
-define(NS_ADDRESS, "http://jabber.org/protocol/address").

-define(PURGE_PROCNAME, ejabberd_mod_multicast_purgeloop).

%% TODO: allow configuration instead of hard-coding
%% Time in seconds
-define(MAXTIME_CACHE_POSITIVE, 86400).
-define(MAXTIME_CACHE_NEGATIVE, 86400).

%% Time in miliseconds
-define(CACHE_PURGE_TIMER, 86400000). % Purge the cache every 24 hours
-define(DISCO_QUERY_TIMEOUT, 10000). % After 10 seconds of delay the server is declared dead


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(LServerS, Opts) ->
	Proc = gen_mod:get_module_proc(LServerS, ?PROCNAME),
	gen_server:start_link({local, Proc}, ?MODULE, [LServerS, Opts], []).

start(LServerS, Opts) ->
	Proc = gen_mod:get_module_proc(LServerS, ?PROCNAME),
	ChildSpec =	{
		Proc,
		{?MODULE, start_link, [LServerS, Opts]},
		temporary,
		1000,
		worker,
		[?MODULE]},
	supervisor:start_child(ejabberd_sup, ChildSpec).

stop(LServerS) ->
	Proc = gen_mod:get_module_proc(LServerS, ?PROCNAME),
	gen_server:call(Proc, stop),
	supervisor:terminate_child(ejabberd_sup, Proc),
	supervisor:delete_child(ejabberd_sup, Proc).


%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([LServerS, Opts]) ->
	LServiceS = gen_mod:get_opt(host, Opts, "multicast." ++ LServerS),
	Access = gen_mod:get_opt(access, Opts, all),
	Max_receivers = gen_mod:get_opt(max_receivers, Opts, 50),
	create_cache(),
	try_start_loop(),
	ejabberd_router:register_route(LServiceS),
	{ok, #state{lservice = LServiceS,
		lserver = LServerS,
		access = Access,
		max_receivers = Max_receivers}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
	try_stop_loop(),
	{stop, normal, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({route, From, To, {xmlelement, "iq", _Attrs, _Els} = Packet}, State) ->
	IQ = jlib:iq_query_info(Packet),
	case catch process_iq(From, IQ, State) of
		Result when is_record(Result, iq) ->
			ejabberd_router:route(To, From, jlib:iq_to_xml(Result));
		{'EXIT', Reason} ->
			?ERROR_MSG("Error when processing IQ stanza: ~p", [Reason]),
			Err = jlib:make_error_reply(Packet, ?ERR_INTERNAL_SERVER_ERROR),
			ejabberd_router:route(To, From, Err);
		reply ->
			Pid = list_to_pid(To#jid.resource),
			catch Pid ! {route, From, To, Packet}
	end,
	{noreply, State};

handle_info({route, From, To, {xmlelement, Stanza_type, _, _} = Packet},
		#state{lservice = LServiceS,
			lserver = LServerS,
			access = Access,
			max_receivers = Max_receivers} = State)
		% XEP33 allows only 'message' and 'presence' stanza types
		when (Stanza_type == "message") or (Stanza_type == "presence") ->
	%io:format("Multicast packet: ~nFrom: ~p~nTo: ~p~nPacket: ~p~n", [From, To, Packet]),
	case catch do_route(LServiceS, LServerS, Access, Max_receivers, From, To, Packet) of
		{'EXIT', Reason} ->
			?ERROR_MSG("~p", [Reason]);
		_ ->
			ok
	end,
	{noreply, State};

handle_info({get_host, Pid}, State) ->
	Pid ! {my_host, State#state.lservice},
	{noreply, State};

handle_info(_Info, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
	ejabberd_router:unregister_route(State#state.lservice),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.


%%====================================================================
%%% Internal functions
%%====================================================================


%%%------------------------
%%% IQ Processing
%%%------------------------

%% disco#info request
process_iq(_, #iq{type = get, xmlns = ?NS_DISCO_INFO, lang = Lang} = IQ, _State) ->
	IQ#iq{type = result, sub_el =
		[{xmlelement, "query", [{"xmlns", ?NS_DISCO_INFO}], iq_disco_info(Lang)}]};

%% disco#items request
process_iq(_, #iq{type = get, xmlns = ?NS_DISCO_ITEMS} = IQ, _) ->
	IQ#iq{type = result, sub_el =
		[{xmlelement, "query", [{"xmlns", ?NS_DISCO_ITEMS}], []}]};

%% vCard request
process_iq(_, #iq{type = get, xmlns = ?NS_VCARD, lang = Lang} = IQ, _) ->
	IQ#iq{type = result, sub_el =
		[{xmlelement, "vCard", [{"xmlns", ?NS_VCARD}], iq_vcard(Lang)}]};

%% version request
process_iq(_, #iq{type = get, xmlns = ?NS_VERSION} = IQ, _) ->
	IQ#iq{type = result, sub_el =
		[{xmlelement, "query", [{"xmlns", ?NS_VERSION}], iq_version()}]};

%% Unknown "set" or "get" request
process_iq(_, #iq{type=Type, sub_el=SubEl} = IQ, _) when Type==get; Type==set ->
	IQ#iq{type = error, sub_el = [SubEl, ?ERR_SERVICE_UNAVAILABLE]};

%% IQ "result" or "error".
process_iq(_, reply, _) ->
	reply;

%% IQ "result" or "error".
process_iq(_, _, _) ->
	ok.

-define(FEATURE(Feat), {xmlelement,"feature",[{"var", Feat}],[]}).

iq_disco_info(Lang) ->
	[{xmlelement, "identity",
		[{"category", "service"},
		{"type", "multicast"},
		{"name", translate:translate(Lang, "Multicast")}], []},
	?FEATURE(?NS_DISCO_INFO),
	?FEATURE(?NS_DISCO_ITEMS),
	?FEATURE(?NS_VCARD),
	?FEATURE(?NS_ADDRESS)].

iq_vcard(Lang) ->
	[{xmlelement, "FN", [],
		[{xmlcdata, "ejabberd/mod_multicast"}]},
	{xmlelement, "URL", [],
		[{xmlcdata, ?EJABBERD_URI}]},
	{xmlelement, "DESC", [],
		[{xmlcdata, translate:translate(Lang, "ejabberd Multicast service\n"
		"Copyright (c) 2007 Alexey Shchepin")}]}].

iq_version() ->
	[{xmlelement, "name", [],
		[{xmlcdata, "mod_multicast"}]},
	{xmlelement, "version", [],
		[{xmlcdata, ?VERSION_MULTICAST}]}].


%%%-------------------------
%%% Route 0: Check user
%%%-------------------------

do_route(LServiceS, LServerS, Access, Max_receivers, From, To, Packet) ->
	case acl:match_rule(LServerS, Access, From) of
		allow ->
			do_route1(LServiceS, LServerS, Max_receivers, From, To, Packet);
		_ ->
			route_error(To, From, Packet, forbidden, "Access denied by service policy")
	end.


%%%-------------------------
%%% Route 1: Check packet
%%%-------------------------

do_route1(LServiceS, LServerS, Max_receivers, From, To, Packet) ->
	case get_adrs_el(Packet) of
		{correct, Addresses_xml} ->
			do_route2(LServiceS, LServerS, Max_receivers, From, To, Packet, Addresses_xml);
		{error, Error_text} ->
			route_error(To, From, Packet, bad_request, Error_text)
	end.

get_adrs_el(Packet) ->
	case xml:get_subtag(Packet, "addresses") of
		{xmlelement, _, PAttrs, Addresses_xml} ->
			case xml:get_attr_s("xmlns", PAttrs) of
				?NS_ADDRESS -> 
					case get_address_els(Addresses_xml) of
						[] -> {error, "no address elements found"};
						Addresses -> {correct, Addresses}
					end;
				_ -> {error, "wrong xmlns"}
			end;
		_ -> {error, "no addresses element found"}
	end.

%% Given a list of xmlelements, some may be of "address" type,
%% return a list of only the attributes of those "address" elements
get_address_els(Addresses_xml) ->
	lists:foldl(
		fun(XML, R) ->
			case XML of
				{xmlelement, "address", Attrs, _El} ->
					case xml:get_attr_s("delivered", Attrs) of
						"true" -> R;
						_ ->
							Type = xml:get_attr_s("type", Attrs),
							case Type of
								"to" -> [Attrs|R];
								"cc" -> [Attrs|R];
								"bcc" -> [Attrs|R];
								_ -> R
							end
					end;
				_ -> R
			end
		end,
		[],
		Addresses_xml).


%%%-------------------------
%%% Route 2: Format list of destinations
%%%-------------------------

do_route2(LServiceS, LServerS, Max_receivers, From1, To, Packet, Addresses) ->
	From = jlib:jid_to_string(From1),

	case length(Addresses) > Max_receivers of
		false -> ok;
		true ->
			route_error(To, From, Packet, not_acceptable,
			"Too many receiver fields were specified")
	end,

	{JIDs, URIs, Others} = split_dests(Addresses),

	send_error_address(From1, Packet, URIs, Others),

	Grouped_addresses = group_dests_by_servers(JIDs),

	% Check if this packet requires relay
	FromJID = jlib:string_to_jid(From),
	case check_relay_required(FromJID#jid.server, LServerS, Grouped_addresses) of
		false -> do_route3(LServiceS, LServerS, From, Packet, Grouped_addresses);
		true ->
			% The packet requires relaying, but it is not allowed
			% So let's abort and return error
			route_error(To, FromJID, Packet, forbidden,
			"Relaying denied by service policy")
	end.

%% Sends an error message for each unknown address
%% Currently only 'jid' addresses are acceptable on ejabberd
send_error_address(From, Packet, URIs, Others) ->
	URIs2 = ["uri: " ++ URI || URI <- URIs],
	Others2 = [io_lib:format("~p", [Other]) || Other <- Others],
	Unknown_adds = URIs2 ++ Others2,
	[route_error(From, From, Packet, jid_malformed, 
			"The service does not understand the address: " ++ A)
		|| A <- Unknown_adds].

%% Split the list of destinations depending on the address type
split_dests(Addresses) ->
	lists:foldl(
		fun(Addr, {Jids1, Uris1, Others1}) ->
			{Jid2, Uri2, Other2} =
				case {xml:get_attr_s("jid", Addr), xml:get_attr_s("uri", Addr)} of
					{[], []} -> {[], [], [Addr]};
					{Jid, []} -> {[Jid], [], []};
					{[], Uri} -> {[], [Uri], []};
					{_Jid, _Uri} -> {[], [], [Addr]}
				end,
				{Jids1 ++ Jid2, Uris1 ++ Uri2, Others1 ++ Other2}
		end,
		{[], [], []},
		Addresses).

%% Group destinations by their servers
group_dests_by_servers(Jids) ->
	D = lists:foldl(
		fun(Jid, Dict) ->
			ServerS = (stj(Jid))#jid.server,
			dict:append(ServerS, Jid, Dict)
		end,
		dict:new(),
		Jids),
	Keys = dict:fetch_keys(D),
	[ {Key, dict:fetch(Key, D)} || Key <- Keys ].


%%%-------------------------
%%% Route 3: Look for cached responses
%%%-------------------------

do_route3(LServiceS, LServerS, From, Packet, Grouped_addresses) ->
	Maxtime_positive = ?MAXTIME_CACHE_POSITIVE,
	Maxtime_negative = ?MAXTIME_CACHE_NEGATIVE,

	% Fill all the possible data from the cache
	Grouped_addresses2 = lists:map(
		fun({RServer, JIDs}) ->
			Cached_response = search_server_on_cache(RServer, LServerS, {Maxtime_positive, Maxtime_negative}),
			{RServer, JIDs, Cached_response}
		end,
		Grouped_addresses),

	% Check if some server is unknown
	All_servers_known = lists:all(
		fun({_RServer, _JIDs, Cached_response2}) ->
			found == (catch element(1, Cached_response2))
		end,
		Grouped_addresses2),

	Fun = case All_servers_known of
		% If all servers are known, continue the execution as usual
		true -> apply;
		% If any server is unknown, let's spawn a process to serve it
		false -> spawn
	end,
	apply(erlang, Fun, [?MODULE, do_route4, [LServiceS, LServerS, From, Packet, Grouped_addresses2]]).


%%%-------------------------
%%% Route 4: Ask multicast support and send packets
%%%-------------------------

do_route4(LServiceS, LServerS, From, Packet, Grouped_addresses2) ->
	Grouped_addresses3 = add_multicast_response(Grouped_addresses2, LServerS, LServiceS),
	build_send_packet(Grouped_addresses3, From, Packet).

%% Try to find multicast service for each server group
%% If not, split group
%% And produce the final list of destinations
add_multicast_response(Grouped_addresses, LServerS, LServiceS) ->
	lists:foldl(
		fun(Group, R) ->
			{RServer, JIDs, Cached_response} = Group,
			R ++ case check_server_support(RServer, Cached_response, LServerS, LServiceS) of
				local ->
					[{JID, local_user} || JID <- JIDs];
				not_supported ->
					[{JID, no_multicast} || JID <- JIDs];
				RServiceJID ->
					[{JIDs, {multicast, RServiceJID}}]
			end
		end,
		[],
		Grouped_addresses).

%% Send to all, for each group
build_send_packet(List, From, Packet) ->
	lists:foreach(
		fun({Jids, Multicast}) ->
			{To2, Dests} = case Multicast of
				local_user -> {Jids, []};
				no_multicast -> {Jids, []};
				{multicast, Service} -> {Service, Jids}
			end,
			Packet2 = update_addresses_xml(Packet, Dests),
			Packet3 = xml:replace_tag_attr("to", To2, Packet2),
			ejabberd_router:route(stj(From), stj(To2), Packet3)
		end,
		List).


%%%-------------------------
%%% Check relay
%%%-------------------------

%% If the sender is external, and at least one destination is external,
%% then this package requires relaying
check_relay_required(RServer, LServerS, Grouped_addresses) ->
	case string:str(RServer, LServerS) > 0 of
		true -> false;
		false -> check_relay_required(LServerS, Grouped_addresses)
	end.

check_relay_required(LServerS, Grouped_addresses) ->
	lists:any(
		fun({RServer, _JIDs}) ->
			RServer /= LServerS
		end,
		Grouped_addresses).


%%%-------------------------
%%% Tags
%%%-------------------------

%% For each address which server is not the local one, add delivered=true
%% If the address' type == bcc, remove address from list
update_addresses_xml(Packet, Dests) ->
	% get addresses
	{xmlelement, _, PAttrs, Addresses_xml} = xml:get_subtag(Packet, "addresses"),
	Addresses_xml2 = lists:map(
		fun(XML) ->
			case XML of
				{xmlelement, "address", Attrs, _El} ->
					case xml:get_attr_s("delivered", Attrs) of
						"true" -> XML;
						_ ->
							JID = xml:get_attr_s("jid", Attrs),
							Is_multicast_dest = lists:member(JID, Dests),
							Type = xml:get_attr_s("type", Attrs),
							case {Is_multicast_dest, Type} of
								{true, _} -> XML;
								{false, "to"} -> add_delivered(XML);
								{false, "cc"} -> add_delivered(XML);
								{false, "bcc"} -> [];
								{false, _} -> XML
							end
					end;
				{xmlcdata, _} -> [];
				_ -> XML
			end
		end,
		Addresses_xml),
	Addresses_elements = case lists:flatten(Addresses_xml2) of
		[] -> [];
		E -> [{xmlelement, "addresses", PAttrs, E}]
	end,
	replace_tag_el("addresses", Addresses_elements, Packet).

add_delivered({xmlelement, Name, Attrs, Els}) ->
	Attrs2 = Attrs ++ [{"delivered", "true"}],
	{xmlelement, Name, Attrs2, Els}.

replace_tag_el(El, Elements, {xmlelement, Name, Attrs, Els}) ->
	Els1 = lists:keydelete(El, 2, Els),
	Els2 = Els1 ++ Elements,
	{xmlelement, Name, Attrs, Els2}.


%%%-------------------------
%%% Check protocol support
%%%-------------------------

check_server_support(RServer, Cached_response, _LServer, LServiceS) ->
	case Cached_response of
		{found, local_server} ->
			local;

		{found, Response} ->
			Response;

		{obsolete, not_supported} ->
			Response = query_server_childs(RServer, LServiceS),
			add_response(RServer, Response),
			Response;

		{obsolete, RService} ->
			% Ask this service again, it will probably support
			Response = case query_this(RService, LServiceS) of
				true -> RService;
				% If negative, ask server and childs
				false -> query_server_childs(RServer, LServiceS)
			end,
			add_response(RServer, Response),
			Response;

		not_found ->
			Response = query_server_childs(RServer, LServiceS),
			add_response(RServer, Response),
			Response

	end.

%% Returns not_supported or the service
query_server_childs(RServer, LServiceS) ->
	case query_this(RServer, LServiceS) of
		true -> stj(RServer);
		false ->
			Childs = get_child_els(RServer, LServiceS),
			% Ask each child
			case lists:dropwhile(fun(Child) -> not query_this(Child, LServiceS) end, Childs) of
				[] -> not_supported;
				List -> hd(List)
			end
	end.

%% Ask the server for its disco items
get_child_els(RServer, LServiceJID) ->
	Packet = {xmlelement, "iq",
		[{"to", RServer}, {"type", "get"}],
		[{xmlelement, "query", [{"xmlns", ?NS_DISCO_ITEMS}], []}]},
	
	Childs = route_and_receive(stj(LServiceJID), stj(RServer), Packet),

	% Convert answer to list
	% For each one, if it's "item", look for jid
	lists:foldl(
		fun(XML, Res) ->
			case XML of
				{xmlelement, "item", Attrs, _} ->
					Res ++ [xml:get_attr_s("jid", Attrs)];
				_ -> Res
			end
		end,
		[],
		Childs).

%% Ask the server if it supports XEP33
%% Returns true or false
query_this(RServerS, LServiceS) ->
	Packet = {xmlelement, "iq",
		[{"to", RServerS}, {"type", "get"}],
		[{xmlelement, "query", [{"xmlns", ?NS_DISCO_INFO}], []}]},
	
	Features = route_and_receive(stj(LServiceS), stj(RServerS), Packet),

	% Convert answer to list
	% For each one, if it's "feature", look for var
	lists:any(
		fun(XML) ->
			case XML of
				{xmlelement, "feature", Attrs, _} ->
					?NS_ADDRESS == xml:get_attr_s("var", Attrs);
				_ -> false
			end
		end,
		Features).

%% Route the request and wait to receive the response
%% It is very important to only accept a packet that is routed exactly
%% from this destination and to ourselves
route_and_receive(From, To, Packet) ->
	% Add the Pid of this process as the resource
	% TODO: investigate if this is the best solution
	My_pid_resource = pid_to_list(self()),
	From2 = From#jid{
		resource = My_pid_resource,
		lresource = My_pid_resource
		},
	% Send packet
	ejabberd_router:route(From2, To, Packet),
	% Wait for answer
	receive {route, To, From2, IQ} ->
		{xmlelement, "query", _, List} = xml:get_subtag(IQ, "query"),
		List
	after ?DISCO_QUERY_TIMEOUT -> % in miliseconds
		[]
	end.
	

%%%-------------------------
%%% Cache
%%%-------------------------

create_cache() ->
	mnesia:create_table(multicastc, [{ram_copies, [node()]},
		{attributes, record_info(fields, multicastc)}]).

%% Add this response to the cache.
%% If a previous response still exists, it's overwritten
add_response(RServer, Response) ->
	Secs = calendar:datetime_to_gregorian_seconds(calendar:now_to_datetime(now())),
	mnesia:dirty_write(#multicastc{
		rserver = RServer,
		response = Response,
		ts = Secs}).

%% Search on the cache if there is a response for the server
%% If there is a response but is obsolete,
%% don't bother removing since it will later be overwritten anyway
search_server_on_cache(RServer, LServerS, _Maxmins)
		when RServer == LServerS ->
	{found, local_server};

search_server_on_cache(RServer, _LServerS, Maxmins) ->
	case look_server(RServer) of
		not_found ->
			not_found;
		{found, Response, Ts} ->
			Now = calendar:datetime_to_gregorian_seconds(calendar:now_to_datetime(now())),
			case is_obsolete(Response, Ts, Now, Maxmins) of
				false -> {found, Response};
				true -> {obsolete, Response}
			end
	end.

look_server(RServer) ->
	case mnesia:dirty_read(multicastc, RServer) of
		[] -> not_found;
		[M] -> {found, M#multicastc.response, M#multicastc.ts}
	end.

is_obsolete(Response, Ts, Now, {Max_pos, Max_neg}) ->
	Max = case Response of
		not_supported -> Max_neg;
		_ -> Max_pos
	end,
	(Now - Ts) > Max.


%%%-------------------------
%%% Purge
%%%-------------------------

purge() ->
	Maxmins_positive = ?MAXTIME_CACHE_POSITIVE,
	Maxmins_negative = ?MAXTIME_CACHE_NEGATIVE,
	Now = calendar:datetime_to_gregorian_seconds(calendar:now_to_datetime(now())),
	purge(Now, {Maxmins_positive, Maxmins_negative}).

purge(Now, Maxmins) ->
	F = fun() ->
		mnesia:foldl(
			fun(R, _) ->
				#multicastc{response = Response, ts = Ts} = R,
				% If this record is obsolete, delete it
				case is_obsolete(Response, Ts, Now, Maxmins) of
					true -> mnesia:delete_object(R);
					false -> ok
				end
			end,
			none,
			multicastc)
		end,
	mnesia:transaction(F).


%%%-------------------------
%%% Purge loop
%%%-------------------------

try_start_loop() ->
	case lists:member(?PURGE_PROCNAME, registered()) of
		true -> ok;
		false -> start_loop()
	end,
	?PURGE_PROCNAME ! new_module.

start_loop() ->
	register(?PURGE_PROCNAME, spawn(?MODULE, purge_loop, [0])),
	?PURGE_PROCNAME ! purge_now.

try_stop_loop() ->
	?PURGE_PROCNAME ! try_stop.

% NM = number of modules are running on this node
purge_loop(NM) ->
	receive
		purge_now ->
			purge(),
			timer:send_after(?CACHE_PURGE_TIMER, ?PURGE_PROCNAME, purge_now),
			purge_loop(NM);
		new_module ->
			purge_loop(NM + 1);
		try_stop when NM > 1 ->
			purge_loop(NM - 1);
		try_stop ->
			purge_loop_finished
	end.


%%%-------------------------
%%% Error report
%%%-------------------------

route_error(From, To, Packet, ErrType, ErrText) ->
	{xmlelement, _Name, Attrs, _Els} = Packet,
	Lang = xml:get_attr_s("xml:lang", Attrs),
	Reply = make_reply(ErrType, Lang, ErrText),
	Err = jlib:make_error_reply(Packet, Reply),
	ejabberd_router:route(From, To, Err).

make_reply(bad_request, Lang, ErrText) ->
	?ERRT_BAD_REQUEST(Lang, ErrText);
make_reply(jid_malformed, Lang, ErrText) ->
	?ERRT_JID_MALFORMED(Lang, ErrText);
make_reply(not_acceptable, Lang, ErrText) ->
	?ERRT_NOT_ACCEPTABLE(Lang, ErrText);
make_reply(forbidden, Lang, ErrText) ->
	?ERRT_FORBIDDEN(Lang, ErrText).

stj(String) -> jlib:string_to_jid(String).


%%%-------------------------
%%% Exported multicast functions 
%%%-------------------------

route_packet_multicast(From, Destinations, Multicast_service, Packet) ->
	% Build and addresses element
	Ad_list = lists:map(
		fun(JID) ->
			build_address_element(jlib:jid_to_string(JID))
		end,
		Destinations),
	Element = build_addresses_element(Ad_list),

	% Add element to original packet
	{xmlelement, Type, Attrs, Els} = Packet,
	Els2 = [Element | Els],
	Packet_multicast = {xmlelement, Type, Attrs, Els2},

	% Finally, send the packet to the multicast service
	ejabberd_router:route(
		From,
		jlib:string_to_jid(Multicast_service),
		Packet_multicast).

build_address_element(Jid_string) ->
	{xmlelement, "address", 
		[{"type", "bcc"}, {"jid", Jid_string}], 
		[]}.

build_addresses_element(Addresses_list) ->
	{xmlelement, "addresses", 
		[{"xmlns", "http://jabber.org/protocol/address"}], 
		Addresses_list}.
