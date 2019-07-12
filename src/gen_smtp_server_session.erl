%%% Copyright 2009 Andrew Thompson <andrew@hijacked.us>. All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%
%%%   1. Redistributions of source code must retain the above copyright notice,
%%%      this list of conditions and the following disclaimer.
%%%   2. Redistributions in binary form must reproduce the above copyright
%%%      notice, this list of conditions and the following disclaimer in the
%%%      documentation and/or other materials provided with the distribution.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE FREEBSD PROJECT ``AS IS'' AND ANY EXPRESS OR
%%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
%%% EVENT SHALL THE FREEBSD PROJECT OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
%%% INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
%%% (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
%%% ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
%%% SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

%% @doc Process representing a SMTP session, extensible via a callback module. This
%% module is implemented as a behaviour that the callback module should
%% implement. To see the details of the required callback functions to provide,
%% please see `smtp_server_example'.
%% @see smtp_server_example

-module(gen_smtp_server_session).
-behaviour(gen_server).
-behaviour(ranch_protocol).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(MAXIMUMSIZE, 10485760). %10mb
-define(BUILTIN_EXTENSIONS, [{"SIZE", "10485670"}, {"8BITMIME", true}, {"PIPELINING", true}]).
-define(TIMEOUT, 180000). % 3 minutes

%% External API
-export([start_link/4]).
-export([ranch_init/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
		code_change/3]).

-record(envelope,
	{
		from :: binary() | 'undefined',
		to = [] :: [binary()],
		data = <<>> :: binary(),
		expectedsize = 0 :: pos_integer() | 0,
		auth = {<<>>, <<>>} :: {binary(), binary()} % {"username", "password"}
	}
).

-record(state,
	{
		socket = erlang:error({undefined, socket}) :: port() | tuple(),
		module = erlang:error({undefined, module}) :: atom(),
        transport :: module(),
        ranch_ref :: ranch:ref(),
		envelope = undefined :: 'undefined' | #envelope{},
		extensions = [] :: [{string(), string()}],
		waitingauth = false :: 'false' | 'plain' | 'login' | 'cram-md5',
		authdata :: 'undefined' | binary(),
		readmessage = false :: boolean(),
		tls = false :: boolean(),
		callbackstate :: any(),
		options = [] :: [tuple()]
	}
).

-type(state() :: any()).
-type(error_message() :: {error, string(), state()}).

-callback code_change(OldVsn :: any(), State :: state(), Extra :: any()) ->  {ok, state()}.
-callback handle_HELO(Hostname :: binary(), State :: state()) ->
    {ok, pos_integer(), state()} | {ok, state()} | error_message().
-callback handle_EHLO(Hostname :: binary(), Extensions :: list(), State :: state()) ->
    {ok, list(), state()} | error_message().
-callback handle_MAIL(From :: binary(), State :: state()) ->
    {ok, state()} | {error, string(), state()}.
-callback handle_MAIL_extension(Extension :: binary(), State :: state()) ->
    {ok, state()} | error.
-callback handle_RCPT(To :: binary(), State :: state()) ->
    {ok, state()} | {error, string(), state()}.
-callback handle_RCPT_extension(Extension :: binary(), State :: state()) ->
    {ok, state()} | error.
-callback handle_DATA(From :: binary(), To :: [binary(),...], Data :: binary(), State :: state()) ->
    {ok, string(), state()} | {error, string(), state()}.
-callback handle_RSET(State :: state()) -> state().
-callback handle_VRFY(Address :: binary(), State :: state()) ->
    {ok, string(), state()} | {error, string(), state()}.
-callback handle_other(Verb :: binary(), Args :: binary(), state()) ->
                          {string() | noreply, state()}.
-callback handle_info(Info :: term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: term()}.

-optional_callbacks([handle_info/2]).

%% @doc Start a SMTP session linked to the calling process.
%% @see start/3
-spec start_link(Ref :: ranch:ref(), _Socket :: _, Transport :: module(), Options :: [tuple()]) ->
                        {'ok', pid()}.
start_link(Ref, _Socket, Transport, Options) ->
    {ok, proc_lib:spawn_link(?MODULE, ranch_init, [{Ref, Transport, Options}])}.

%% %% @doc Start a SMTP session. Arguments are `Socket' (probably opened via
%% %% `gen_smtp_server' or an analogue), which is an abstract socket implemented
%% %% via the `socket' module, `Module' is the name of the callback module
%% %% implementing the SMTP session behaviour that you'd like to use and `Options'
%% %% is the optional arguments provided by the accept server.
%% -spec start(Socket :: port(), Module :: atom(), Options :: [tuple()]) -> {'ok', pid()} | 'ignore' | {'error', any()}.
%% start(Socket, Module, Options) ->
%% 	gen_server:start(?MODULE, [Socket, Module, Options], []).

ranch_init({Ref, Transport, Opts}) ->
    {ok, Socket} = ranch:handshake(Ref),
    case init([Ref, Transport, Socket, Opts]) of
        {ok, State, Timeout} ->
            %% ok = Transport:setopts(Socket,
            %%                        [{active, once},
            %%                         {recbuf, ?MAX_SOCK_BUF_SIZE},
            %%                         {sndbuf, ?MAX_SOCK_BUF_SIZE},
            %%                         {buffer, ?MAX_SOCK_BUF_SIZE}
            %%                        ]),
            gen_server:enter_loop(?MODULE, [], State, Timeout);
        {stop, Reason} ->
            exit(Reason)
    end.

%% @private
-spec init(Args :: list()) -> {'ok', #state{}, ?TIMEOUT} | {'stop', any()} | 'ignore'.
init([Ref, Transport, Socket, Options]) ->
    Module = proplists:get_value(callback, Options),
	PeerName = case Transport:peername(Socket) of
		{ok, {IPaddr, _Port}} -> IPaddr;
		{error, _} -> error
	end,
	case PeerName =/= error
		andalso Module:init(hostname(Options),
                            proplists:get_value(sessioncount, Options, 0), %FIXME
                            PeerName,
                            proplists:get_value(callbackoptions, Options, []))
	of
		false ->
			Transport:close(Socket),
			ignore;
		{ok, Banner, CallbackState} ->
			Transport:send(Socket, ["220 ", Banner, "\r\n"]),
            ok = Transport:setopts(Socket, [{active, once}]),
			{ok, #state{socket = Socket,
                        transport = Transport,
                        module = Module,
                        ranch_ref = Ref,
                        options = Options,
                        callbackstate = CallbackState}, ?TIMEOUT};
		{stop, Reason, Message} ->
			Transport:send(Socket, [Message, "\r\n"]),
			Transport:close(Socket),
			{stop, Reason};
		ignore ->
			Transport:close(Socket),
			ignore
	end.

%% @hidden
handle_call(stop, _From, State) ->
	{stop, normal, ok, State};

handle_call(Request, _From, State) ->
	{reply, {unknown_call, Request}, State}.

%% @hidden
handle_cast(_Msg, State) ->
	{noreply, State}.

%% @hidden
-spec handle_info(Message :: any(), State :: #state{}) -> {'noreply', #state{}} | {'stop', any(), #state{}}.
handle_info({receive_data, {error, size_exceeded}}, #state{readmessage = true} = State) ->
	send(State, "552 Message too large\r\n"),
    setopts(State, [{active, once}]),
	{noreply, State#state{readmessage = false, envelope = #envelope{}}, ?TIMEOUT};
handle_info({receive_data, {error, bare_newline}}, #state{readmessage = true} = State) ->
	send(State, "451 Bare newline detected\r\n"),
    setopts(State, [{active, once}]),
	{noreply, State#state{readmessage = false, envelope = #envelope{}}, ?TIMEOUT};
handle_info({receive_data, Body, Rest},
            #state{socket = Socket, transport = Transport, readmessage = true, envelope = Env, module=Module,
                   callbackstate = OldCallbackState,  extensions = Extensions} = State) ->
	% send the remainder of the data...
	case Rest of
		<<>> -> ok; % no remaining data
		_ -> self() ! {get_proto(Transport), Socket, Rest}
	end,
	setopts(State, [{packet, line}]),
	%% Unescape periods at start of line (rfc5321 4.5.2)
	UnescapedBody = re:replace(Body, <<"^\\\.">>, <<>>, [global, multiline, {return, binary}]),
	Envelope = Env#envelope{data = UnescapedBody},% size = length(Body)},
	Valid = case has_extension(Extensions, "SIZE") of
		{true, Value} ->
			case byte_size(Envelope#envelope.data) > list_to_integer(Value) of
				true ->
					send(State, "552 Message too large\r\n"),
					setopts(State, [{active, once}]),
					false;
				false ->
					true
			end;
		false ->
			true
	end,
	case Valid of
		true ->
			case Module:handle_DATA(Envelope#envelope.from, Envelope#envelope.to, Envelope#envelope.data, OldCallbackState) of
				{ok, Reference, CallbackState} ->
					send(State, io_lib:format("250 queued as ~s\r\n", [Reference])),
					setopts(State, [{active, once}]),
					{noreply, State#state{readmessage = false,
                                          envelope = #envelope{},
                                          callbackstate = CallbackState}, ?TIMEOUT};
				{error, Message, CallbackState} ->
					send(State, [Message, "\r\n"]),
					setopts(State, [{active, once}]),
					{noreply, State#state{readmessage = false,
                                          envelope = #envelope{},
                                          callbackstate = CallbackState}, ?TIMEOUT}
			end;
		false ->
			% might not even be able to get here anymore...
			{noreply, State#state{readmessage = false, envelope = #envelope{}}, ?TIMEOUT}
	end;
handle_info({SocketType, Socket, Packet}, #state{socket = Socket, transport = Transport} = State)
  when SocketType =:= tcp; SocketType =:= ssl ->
    %% io:format("data: ~p~n", [Packet]),
	case handle_request(parse_request(Packet), State) of
		{ok,  #state{extensions = Extensions,  options = Options, readmessage = true} = NewState} ->
			MaxSize = case has_extension(Extensions, "SIZE") of
				{true, Value} ->
					list_to_integer(Value);
				false ->
					?MAXIMUMSIZE
			end,
			Session = self(),
			Size = 0,
			setopts(NewState, [{packet, raw}]),
            %% TODO: change to receive asynchronously in the same process
			spawn_opt(fun() ->
                              receive_data(
                                [], Transport, Socket, 0, Size, MaxSize, Session, Options)
                      end,
                      [link, {fullsweep_after, 0}]),
			{noreply, NewState, ?TIMEOUT};
		{ok, NewState} ->
			setopts(NewState, [{active, once}]),
			{noreply, NewState, ?TIMEOUT};
		{stop, Reason, NewState} ->
			{stop, Reason, NewState}
	end;
handle_info({tcp_closed, _Socket}, State) ->
	{stop, normal, State};
handle_info({ssl_closed, _Socket}, State) ->
	{stop, normal, State};
handle_info(timeout, #state{socket = Socket, transport = Transport} = State) ->
	send(State, "421 Error: timeout exceeded\r\n"),
	Transport:close(Socket),
	{stop, normal, State};
handle_info(Info, #state{module=Module, callbackstate = OldCallbackState} = State) ->
	case erlang:function_exported(Module, handle_info, 2) of
		true ->
			case Module:handle_info(Info, OldCallbackState) of
				{noreply, NewCallbackState} ->
					{noreply, State#state{callbackstate = NewCallbackState}};
				{noreply, NewCallbackState, Action} ->
					{noreply, State#state{callbackstate = NewCallbackState}, Action};
				{stop, Reason, NewCallbackState} ->
					{stop, Reason, State#state{callbackstate = NewCallbackState}}
			end;
		false ->
			{noreply, State}
	end.

%% @hidden
-spec terminate(Reason :: any(), State :: #state{}) -> 'ok'.
terminate(Reason, #state{socket = Socket, transport = Transport, module = Module,
                         callbackstate = CallbackState}) ->
	ok = Transport:close(Socket),
	Module:terminate(Reason, CallbackState).

%% @hidden
-spec code_change(OldVsn :: any(), State :: #state{}, Extra :: any()) ->  {'ok', #state{}}.
code_change(OldVsn, #state{module = Module, callbackstate = CallbackState} = State, Extra) ->
	% TODO - this should probably be the callback module's version or its checksum
	CallbackState =
		case catch Module:code_change(OldVsn, CallbackState, Extra) of
			{ok, NewCallbackState} -> NewCallbackState;
			_                      -> CallbackState
		end,
	{ok, State#state{callbackstate = CallbackState}}.

-spec parse_request(Packet :: binary()) -> {binary(), binary()}.
parse_request(Packet) ->
	Request = binstr:strip(binstr:strip(binstr:strip(binstr:strip(Packet, right, $\n), right, $\r), right, $\s), left, $\s),
	case binstr:strchr(Request, $\s) of
		0 ->
			% io:format("got a ~s request~n", [Request]),
			case binstr:to_upper(Request) of
				<<"QUIT">> = Res -> {Res, <<>>};
				<<"DATA">> = Res -> {Res, <<>>};
				% likely a base64-encoded client reply
				_ -> {Request, <<>>}
			end;
		Index ->
			Verb = binstr:substr(Request, 1, Index - 1),
			Parameters = binstr:strip(binstr:substr(Request, Index + 1), left, $\s),
			%io:format("got a ~s request with parameters ~s~n", [Verb, Parameters]),
			{binstr:to_upper(Verb), Parameters}
	end.

-spec handle_request({Verb :: binary(), Args :: binary()}, State :: #state{}) -> {'ok', #state{}} | {'stop', any(), #state{}}.
handle_request({<<>>, _Any}, State) ->
	send(State, "500 Error: bad syntax\r\n"),
	{ok, State};
handle_request({<<"HELO">>, <<>>}, State) ->
	send(State, "501 Syntax: HELO hostname\r\n"),
	{ok, State};
handle_request({<<"HELO">>, Hostname},
               #state{options = Options, module = Module, callbackstate = OldCallbackState} = State) ->
	case Module:handle_HELO(Hostname, OldCallbackState) of
		{ok, MaxSize, CallbackState} when is_integer(MaxSize) ->
            Data = ["250 ", hostname(Options), "\r\n"],
			send(State, Data),
			{ok, State#state{extensions = [{"SIZE", integer_to_list(MaxSize)}],
                             envelope = #envelope{},
                             callbackstate = CallbackState}};
		{ok, CallbackState} ->
            Data = ["250 ", hostname(Options), "\r\n"],
			send(State, Data),
			{ok, State#state{envelope = #envelope{}, callbackstate = CallbackState}};
		{error, Message, CallbackState} ->
			send(State, [Message, "\r\n"]),
			{ok, State#state{callbackstate = CallbackState}}
	end;
handle_request({<<"EHLO">>, <<>>}, State) ->
	send(State, "501 Syntax: EHLO hostname\r\n"),
	{ok, State};
handle_request({<<"EHLO">>, Hostname}, #state{options = Options, module = Module, callbackstate = OldCallbackState, tls = Tls} = State) ->
	case Module:handle_EHLO(Hostname, ?BUILTIN_EXTENSIONS, OldCallbackState) of
		{ok, Extensions, CallbackState} ->
			case Extensions of
				[] ->
                    Data = ["250 ", hostname(Options), "\r\n"],
					send(State, Data),
					{ok, State#state{extensions = Extensions, callbackstate = CallbackState}};
				_Else ->
					F =
					fun({E, true}, {Pos, Len, Acc}) when Pos =:= Len ->
							{Pos, Len, [["250 ", E, "\r\n"] | Acc]};
						({E, Value}, {Pos, Len, Acc}) when Pos =:= Len ->
							{Pos, Len, [["250 ", E, " ", Value, "\r\n"] | Acc]};
						({E, true}, {Pos, Len, Acc}) ->
							{Pos+1, Len, [["250-", E, "\r\n"] | Acc]};
						({E, Value}, {Pos, Len, Acc}) ->
							{Pos+1, Len, [["250-", E, " ", Value , "\r\n"] | Acc]}
					end,
					Extensions2 = case Tls of
						true ->
							Extensions -- [{"STARTTLS", true}];
						false ->
							Extensions
					end,
					{_, _, Response} = lists:foldl(
                                         F,
                                         {1, length(Extensions2),
                                          [["250-", hostname(Options), "\r\n"]]},
                                         Extensions2),
					%?debugFmt("Respponse ~p~n", [lists:reverse(Response)]),
					send(State, lists:reverse(Response)),
					{ok, State#state{extensions = Extensions2, envelope = #envelope{}, callbackstate = CallbackState}}
			end;
		{error, Message, CallbackState} ->
			send(State, [Message, "\r\n"]),
			{ok, State#state{callbackstate = CallbackState}}
	end;

handle_request({<<"AUTH">>, _Args}, #state{envelope = undefined} = State) ->
	send(State, "503 Error: send EHLO first\r\n"),
	{ok, State};
handle_request({<<"AUTH">>, Args}, #state{extensions = Extensions, envelope = Envelope, options = Options} = State) ->
	case binstr:strchr(Args, $\s) of
		0 ->
			AuthType = Args,
			Parameters = false;
		Index ->
			AuthType = binstr:substr(Args, 1, Index - 1),
			Parameters = binstr:strip(binstr:substr(Args, Index + 1), left, $\s)
	end,

	case has_extension(Extensions, "AUTH") of
		false ->
			send(State, "502 Error: AUTH not implemented\r\n"),
			{ok, State};
		{true, AvailableTypes} ->
			case lists:member(string:to_upper(binary_to_list(AuthType)),
                              string:tokens(AvailableTypes, " ")) of
				false ->
					send(State, "504 Unrecognized authentication type\r\n"),
					{ok, State};
				true ->
					case binstr:to_upper(AuthType) of
						<<"LOGIN">> ->
							% smtp_socket:send(Socket, "334 " ++ base64:encode_to_string("Username:")),
							send(State, "334 VXNlcm5hbWU6\r\n"),
							{ok, State#state{waitingauth = 'login', envelope = Envelope#envelope{auth = {<<>>, <<>>}}}};
						<<"PLAIN">> when Parameters =/= false ->
							% TODO - duplicated below in handle_request waitingauth PLAIN
							case binstr:split(base64:decode(Parameters), <<0>>) of
								[_Identity, Username, Password] ->
									try_auth('plain', Username, Password, State);
								[Username, Password] ->
									try_auth('plain', Username, Password, State);
								_ ->
									% TODO error
									{ok, State}
							end;
						<<"PLAIN">> ->
							send(State, "334\r\n"),
							{ok, State#state{waitingauth = 'plain', envelope = Envelope#envelope{auth = {<<>>, <<>>}}}};
						<<"CRAM-MD5">> ->
							crypto:start(), % ensure crypto is started, we're gonna need it
							String = smtp_util:get_cram_string(hostname(Options)),
							send(State, ["334 ", String, "\r\n"]),
							{ok, State#state{waitingauth = 'cram-md5', authdata=base64:decode(String), envelope = Envelope#envelope{auth = {<<>>, <<>>}}}}
						%"DIGEST-MD5" -> % TODO finish this? (see rfc 2831)
							%crypto:start(), % ensure crypto is started, we're gonna need it
							%Nonce = get_digest_nonce(),
							%Response = io_lib:format("nonce=\"~s\",realm=\"~s\",qop=\"auth\",algorithm=md5-sess,charset=utf-8", Nonce, State#state.hostname),
							%smtp_socket:send(Socket, "334 "++Response++"\r\n"),
							%{ok, State#state{waitingauth = "DIGEST-MD5", authdata=base64:decode_to_string(Nonce), envelope = Envelope#envelope{auth = {[], []}}}}
					end
			end
	end;

% the client sends a response to auth-cram-md5
handle_request({Username64, <<>>}, #state{waitingauth = 'cram-md5', envelope = #envelope{auth = {<<>>, <<>>}}, authdata = AuthData} = State) ->
	case binstr:split(base64:decode(Username64), <<" ">>) of
		[Username, Digest] ->
			try_auth('cram-md5', Username, {Digest, AuthData}, State#state{authdata=undefined});
		_ ->
			% TODO error
			{ok, State#state{waitingauth=false, authdata=undefined}}
	end;

% the client sends a \0username\0password response to auth-plain
handle_request({Username64, <<>>}, #state{waitingauth = 'plain', envelope = #envelope{auth = {<<>>,<<>>}}} = State) ->
	case binstr:split(base64:decode(Username64), <<0>>) of
		[_Identity, Username, Password] ->
			try_auth('plain', Username, Password, State);
		[Username, Password] ->
			try_auth('plain', Username, Password, State);
		_ ->
			% TODO error
			{ok, State#state{waitingauth=false}}
	end;

% the client sends a username response to auth-login
handle_request({Username64, <<>>}, #state{waitingauth = 'login', envelope = #envelope{auth = {<<>>,<<>>}}} = State) ->
	Envelope = State#state.envelope,
	Username = base64:decode(Username64),
	% smtp_socket:send(Socket, "334 " ++ base64:encode_to_string("Password:")),
	send(State, "334 UGFzc3dvcmQ6\r\n"),
	% store the provided username in envelope.auth
	NewState = State#state{envelope = Envelope#envelope{auth = {Username, <<>>}}},
	{ok, NewState};

% the client sends a password response to auth-login
handle_request({Password64, <<>>}, #state{waitingauth = 'login', envelope = #envelope{auth = {Username,<<>>}}} = State) ->
	Password = base64:decode(Password64),
	try_auth('login', Username, Password, State);

handle_request({<<"MAIL">>, _Args}, #state{envelope = undefined} = State) ->
	send(State, "503 Error: send HELO/EHLO first\r\n"),
	{ok, State};
handle_request({<<"MAIL">>, Args}, #state{module = Module, envelope = Envelope, callbackstate = OldCallbackState,  extensions = Extensions} = State) ->
	case Envelope#envelope.from of
		undefined ->
			case binstr:strpos(binstr:to_upper(Args), "FROM:") of
				1 ->
					Address = binstr:strip(binstr:substr(Args, 6), left, $\s),
					case parse_encoded_address(Address) of
						error ->
							send(State, "501 Bad sender address syntax\r\n"),
							{ok, State};
						{ParsedAddress, <<>>} ->
							%io:format("From address ~s (parsed as ~s)~n", [Address, ParsedAddress]),
							case Module:handle_MAIL(ParsedAddress, OldCallbackState) of
								{ok, CallbackState} ->
									send(State, "250 sender Ok\r\n"),
									{ok, State#state{envelope = Envelope#envelope{from = ParsedAddress}, callbackstate = CallbackState}};
								{error, Message, CallbackState} ->
									send(State, [Message, "\r\n"]),
									{ok, State#state{callbackstate = CallbackState}}
							end;
						{ParsedAddress, ExtraInfo} ->
							%io:format("From address ~s (parsed as ~s) with extra info ~s~n", [Address, ParsedAddress, ExtraInfo]),
							Options = [binstr:to_upper(X) || X <- binstr:split(ExtraInfo, <<" ">>)],
							%io:format("options are ~p~n", [Options]),
							 F = fun(_, {error, Message}) ->
									 {error, Message};
								 (<<"SIZE=", Size/binary>>, InnerState) ->
									case has_extension(Extensions, "SIZE") of
										{true, Value} ->
											case list_to_integer(binary_to_list(Size)) > list_to_integer(Value) of
												true ->
													{error, ["552 Estimated message length ", Size, " exceeds limit of ", Value, "\r\n"]};
												false ->
													InnerState#state{envelope = Envelope#envelope{expectedsize = list_to_integer(binary_to_list(Size))}}
											end;
										false ->
											{error, "555 Unsupported option SIZE\r\n"}
									end;
								(<<"BODY=", _BodyType/binary>>, InnerState) ->
									case has_extension(Extensions, "8BITMIME") of
										{true, _} ->
											InnerState;
										false ->
											{error, "555 Unsupported option BODY\r\n"}
									end;
								(X, InnerState) ->
									case Module:handle_MAIL_extension(X, OldCallbackState) of
										{ok, CallbackState} ->
											InnerState#state{callbackstate = CallbackState};
										error ->
											{error, ["555 Unsupported option: ", ExtraInfo, "\r\n"]}
									end
							end,
							case lists:foldl(F, State, Options) of
								{error, Message} ->
									%io:format("error: ~s~n", [Message]),
									send(State, Message),
									{ok, State};
								NewState ->
									%io:format("OK~n"),
									case Module:handle_MAIL(ParsedAddress, State#state.callbackstate) of
										{ok, CallbackState} ->
											send(State, "250 sender Ok\r\n"),
											{ok, State#state{envelope = Envelope#envelope{from = ParsedAddress}, callbackstate = CallbackState}};
										{error, Message, CallbackState} ->
											send(State, [Message, "\r\n"]),
											{ok, NewState#state{callbackstate = CallbackState}}
									end
							end
					end;
				_Else ->
					send(State, "501 Syntax: MAIL FROM:<address>\r\n"),
					{ok, State}
			end;
		_Other ->
			send(State, "503 Error: Nested MAIL command\r\n"),
			{ok, State}
	end;
handle_request({<<"RCPT">>, _Args}, #state{envelope = undefined} = State) ->
	send(State, "503 Error: need MAIL command\r\n"),
	{ok, State};
handle_request({<<"RCPT">>, Args}, #state{envelope = Envelope, module = Module, callbackstate = OldCallbackState} = State) ->
	case binstr:strpos(binstr:to_upper(Args), "TO:") of
		1 ->
			Address = binstr:strip(binstr:substr(Args, 4), left, $\s),
			case parse_encoded_address(Address) of
				error ->
					send(State, "501 Bad recipient address syntax\r\n"),
					{ok, State};
				{<<>>, _} ->
					% empty rcpt to addresses aren't cool
					send(State, "501 Bad recipient address syntax\r\n"),
					{ok, State};
				{ParsedAddress, <<>>} ->
					%io:format("To address ~s (parsed as ~s)~n", [Address, ParsedAddress]),
					case Module:handle_RCPT(ParsedAddress, OldCallbackState) of
						{ok, CallbackState} ->
							send(State, "250 recipient Ok\r\n"),
							{ok, State#state{envelope = Envelope#envelope{to = Envelope#envelope.to ++ [ParsedAddress]}, callbackstate = CallbackState}};
						{error, Message, CallbackState} ->
							send(State, [Message, "\r\n"]),
							{ok, State#state{callbackstate = CallbackState}}
					end;
				{ParsedAddress, ExtraInfo} ->
					% TODO - are there even any RCPT extensions?
					io:format("To address ~s (parsed as ~s) with extra info ~s~n", [Address, ParsedAddress, ExtraInfo]),
					send(State, ["555 Unsupported option: ", ExtraInfo, "\r\n"]),
					{ok, State}
			end;
		_Else ->
			send(State, "501 Syntax: RCPT TO:<address>\r\n"),
			{ok, State}
	end;
handle_request({<<"DATA">>, <<>>}, #state{envelope = undefined} = State) ->
	send(State, "503 Error: send HELO/EHLO first\r\n"),
	{ok, State};
handle_request({<<"DATA">>, <<>>}, #state{envelope = Envelope} = State) ->
	case {Envelope#envelope.from, Envelope#envelope.to} of
		{undefined, _} ->
			send(State, "503 Error: need MAIL command\r\n"),
			{ok, State};
		{_, []} ->
			send(State, "503 Error: need RCPT command\r\n"),
			{ok, State};
		_Else ->
			send(State, "354 enter mail, end with line containing only '.'\r\n"),
			%io:format("switching to data read mode~n", []),

			{ok, State#state{readmessage = true}}
	end;
handle_request({<<"RSET">>, _Any}, #state{envelope = Envelope, module = Module, callbackstate = OldCallbackState} = State) ->
	send(State, "250 Ok\r\n"),
	% if the client sends a RSET before a HELO/EHLO don't give them a valid envelope
	NewEnvelope = case Envelope of
		undefined -> undefined;
		_Something -> #envelope{}
	end,
	{ok, State#state{envelope = NewEnvelope, callbackstate = Module:handle_RSET(OldCallbackState)}};
handle_request({<<"NOOP">>, _Any}, State) ->
	send(State, "250 Ok\r\n"),
	{ok, State};
handle_request({<<"QUIT">>, _Any}, State) ->
	send(State, "221 Bye\r\n"),
	{stop, normal, State};
handle_request({<<"VRFY">>, Address}, #state{module= Module, callbackstate = OldCallbackState} = State) ->
	case parse_encoded_address(Address) of
		{ParsedAddress, <<>>} ->
			case Module:handle_VRFY(ParsedAddress, OldCallbackState) of
				{ok, Reply, CallbackState} ->
					send(State, ["250 ", Reply, "\r\n"]),
					{ok, State#state{callbackstate = CallbackState}};
				{error, Message, CallbackState} ->
					send(State, [Message, "\r\n"]),
					{ok, State#state{callbackstate = CallbackState}}
			end;
		_Other ->
			send(State, "501 Syntax: VRFY username/address\r\n"),
			{ok, State}
	end;
handle_request({<<"STARTTLS">>, <<>>}, #state{socket = Socket, module = Module, tls=false, extensions = Extensions, callbackstate = OldCallbackState, options = Options} = State) ->
	case has_extension(Extensions, "STARTTLS") of
		{true, _} ->
			send(State, "220 OK\r\n"),
			Options1 = case proplists:get_value(certfile, Options) of
				undefined ->
					[];
				CertFile ->
					[{certfile, CertFile}]
			end,
			Options2 = case proplists:get_value(keyfile, Options) of
				undefined ->
					Options1;
				KeyFile ->
					[{keyfile, KeyFile} | Options1]
			end,
            %% Assert that socket is in passive state
            {ok, [{active, false}]} = inet:getopts(Socket, [active]),
			% TODO: certfile and keyfile should be at configurable locations
			case ranch_ssl:handshake(Socket, [{packet, line}, {mode, list}, {ssl_imp, new} | Options2], 5000) of %XXX: see smtp_socket:?SSL_LISTEN_OPTIONS
				{ok, NewSocket} ->
					%io:format("SSL negotiation sucessful~n"),
                    ranch_ssl:setopts(NewSocket, [{packet, line}]),
					{ok, State#state{socket = NewSocket, transport = ranch_ssl, envelope=undefined,
							authdata=undefined, waitingauth=false, readmessage=false,
							tls=true, callbackstate = Module:handle_STARTTLS(OldCallbackState)}};
				{error, Reason} ->
					io:format("SSL handshake failed : ~p~n", [Reason]),
					send(State, "454 TLS negotiation failed\r\n"),
					{ok, State}
			end;
		false ->
			send(State, "500 Command unrecognized\r\n"),
			{ok, State}
	end;
handle_request({<<"STARTTLS">>, <<>>}, State) ->
	send(State, "500 TLS already negotiated\r\n"),
	{ok, State};
handle_request({<<"STARTTLS">>, _Args}, State) ->
	send(State, "501 Syntax error (no parameters allowed)\r\n"),
	{ok, State};
handle_request({Verb, Args}, #state{module = Module, callbackstate = OldCallbackState} = State) ->
    CallbackState =
        case Module:handle_other(Verb, Args, OldCallbackState) of
            {noreply, CState1} -> CState1;
            {Message, CState1} ->
                send(State, [Message, "\r\n"]),
                CState1
        end,
	{ok, State#state{callbackstate = CallbackState}}.

-spec parse_encoded_address(Address :: binary()) -> {binary(), binary()} | 'error'.
parse_encoded_address(<<>>) ->
	error; % empty
parse_encoded_address(<<"<@", Address/binary>>) ->
	case binstr:strchr(Address, $:) of
		0 ->
			error; % invalid address
		Index ->
			parse_encoded_address(binstr:substr(Address, Index + 1), [], {false, true})
	end;
parse_encoded_address(<<"<", Address/binary>>) ->
	parse_encoded_address(Address, [], {false, true});
parse_encoded_address(<<" ", Address/binary>>) ->
	parse_encoded_address(Address);
parse_encoded_address(Address) ->
	parse_encoded_address(Address, [], {false, false}).

-spec parse_encoded_address(Address :: binary(), Acc :: list(), Flags :: {boolean(), boolean()}) -> {binary(), binary()} | 'error'.
parse_encoded_address(<<>>, Acc, {_Quotes, false}) ->
	{list_to_binary(lists:reverse(Acc)), <<>>};
parse_encoded_address(<<>>, _Acc, {_Quotes, true}) ->
	error; % began with angle brackets but didn't end with them
parse_encoded_address(_, Acc, _) when length(Acc) > 320 ->
	error; % too long
parse_encoded_address(<<"\\", Tail/binary>>, Acc, Flags) ->
	<<H, NewTail/binary>> = Tail,
	parse_encoded_address(NewTail, [H | Acc], Flags);
parse_encoded_address(<<"\"", Tail/binary>>, Acc, {false, AB}) ->
	parse_encoded_address(Tail, Acc, {true, AB});
parse_encoded_address(<<"\"", Tail/binary>>, Acc, {true, AB}) ->
	parse_encoded_address(Tail, Acc, {false, AB});
parse_encoded_address(<<">", Tail/binary>>, Acc, {false, true}) ->
	{list_to_binary(lists:reverse(Acc)), binstr:strip(Tail, left, $\s)};
parse_encoded_address(<<">", _Tail/binary>>, _Acc, {false, false}) ->
	error; % ended with angle brackets but didn't begin with them
parse_encoded_address(<<" ", Tail/binary>>, Acc, {false, false}) ->
	{list_to_binary(lists:reverse(Acc)), binstr:strip(Tail, left, $\s)};
parse_encoded_address(<<" ", _Tail/binary>>, _Acc, {false, true}) ->
	error; % began with angle brackets but didn't end with them
parse_encoded_address(<<H, Tail/binary>>, Acc, {false, AB}) when H >= $0, H =< $9 ->
	parse_encoded_address(Tail, [H | Acc], {false, AB}); % digits
parse_encoded_address(<<H, Tail/binary>>, Acc, {false, AB}) when H >= $@, H =< $Z ->
	parse_encoded_address(Tail, [H | Acc], {false, AB}); % @ symbol and uppercase letters
parse_encoded_address(<<H, Tail/binary>>, Acc, {false, AB}) when H >= $a, H =< $z ->
	parse_encoded_address(Tail, [H | Acc], {false, AB}); % lowercase letters
parse_encoded_address(<<H, Tail/binary>>, Acc, {false, AB}) when H =:= $-; H =:= $.; H =:= $_ ->
	parse_encoded_address(Tail, [H | Acc], {false, AB}); % dash, dot, underscore
% Allowed characters in the local name: ! # $ % & ' * + - / = ?  ^ _ ` . { | } ~
parse_encoded_address(<<H, Tail/binary>>, Acc, {false, AB}) when H =:= $+;
 	H =:= $!; H =:= $#; H =:= $$; H =:= $%; H =:= $&; H =:= $'; H =:= $*; H =:= $=;
	H =:= $/; H =:= $?; H =:= $^; H =:= $`; H =:= ${; H =:= $|; H =:= $}; H =:= $~ ->
	parse_encoded_address(Tail, [H | Acc], {false, AB}); % other characters
parse_encoded_address(_, _Acc, {false, _AB}) ->
	error;
parse_encoded_address(<<H, Tail/binary>>, Acc, Quotes) ->
	parse_encoded_address(Tail, [H | Acc], Quotes).

-spec has_extension(Extensions :: [{string(), string()}], Extension :: string()) -> {'true', string()} | 'false'.
has_extension(Exts, Ext) ->
	Extension = string:to_upper(Ext),
	Extensions = [{string:to_upper(X), Y} || {X, Y} <- Exts],
	%io:format("extensions ~p~n", [Extensions]),
	case proplists:get_value(Extension, Extensions) of
		undefined ->
			false;
		Value ->
			{true, Value}
	end.


-spec try_auth(AuthType :: 'login' | 'plain' | 'cram-md5', Username :: binary(), Credential :: binary() | {binary(), binary()}, State :: #state{}) -> {'ok', #state{}}.
try_auth(AuthType, Username, Credential, #state{module = Module, envelope = Envelope, callbackstate = OldCallbackState} = State) ->
	% clear out waiting auth
	NewState = State#state{waitingauth = false, envelope = Envelope#envelope{auth = {<<>>, <<>>}}},
	case erlang:function_exported(Module, handle_AUTH, 4) of
		true ->
			case Module:handle_AUTH(AuthType, Username, Credential, OldCallbackState) of
				{ok, CallbackState} ->
					send(State, "235 Authentication successful.\r\n"),
					{ok, NewState#state{callbackstate = CallbackState,
					                    envelope = Envelope#envelope{auth = {Username, Credential}}}};
				_Other ->
					send(State, "535 Authentication failed.\r\n"),
					{ok, NewState}
				end;
		false ->
			io:format("Please define handle_AUTH/4 in your server module or remove AUTH from your module extensions~n"),
			send(State, "535 authentication failed (#5.7.1)\r\n"),
			{ok, NewState}
	end.

%get_digest_nonce() ->
	%A = [io_lib:format("~2.16.0b", [X]) || <<X>> <= erlang:md5(integer_to_list(rand:uniform(4294967295)))],
	%B = [io_lib:format("~2.16.0b", [X]) || <<X>> <= erlang:md5(integer_to_list(rand:uniform(4294967295)))],
	%binary_to_list(base64:encode(lists:flatten(A ++ B))).


%% @doc a tight loop to receive the message body
receive_data(_Acc, _Transport, _Socket, _, Size, MaxSize, Session, _Options) when MaxSize > 0, Size > MaxSize ->
	io:format("message body size ~B exceeded maximum allowed ~B~n", [Size, MaxSize]),
	Session ! {receive_data, {error, size_exceeded}};
receive_data(Acc, Transport, Socket, RecvSize, Size, MaxSize, Session, Options) ->
	case Transport:recv(Socket, RecvSize, 1000) of
		{ok, Packet} when Acc == [] ->
			case check_bare_crlf(Packet, <<>>, proplists:get_value(allow_bare_newlines, Options, false), 0) of
				error ->
					Session ! {receive_data, {error, bare_newline}};
				FixedPacket ->
					case binstr:strpos(FixedPacket, "\r\n.\r\n") of
						0 ->
							%io:format("received ~B bytes; size is now ~p~n", [RecvSize, Size + size(Packet)]),
							%io:format("memory usage: ~p~n", [erlang:process_info(self(), memory)]),
							receive_data([FixedPacket | Acc], Transport, Socket, RecvSize, Size + byte_size(FixedPacket), MaxSize, Session, Options);
						Index ->
							String = binstr:substr(FixedPacket, 1, Index - 1),
							Rest = binstr:substr(FixedPacket, Index+5),
							%io:format("memory usage before flattening: ~p~n", [erlang:process_info(self(), memory)]),
							Result = list_to_binary(lists:reverse([String | Acc])),
							%io:format("memory usage after flattening: ~p~n", [erlang:process_info(self(), memory)]),
							Session ! {receive_data, Result, Rest}
					end
			end;
		{ok, Packet} ->
			[Last | _] = Acc,
			case check_bare_crlf(Packet, Last, proplists:get_value(allow_bare_newlines, Options, false), 0) of
				error ->
					Session ! {receive_data, {error, bare_newline}};
				FixedPacket ->
					case binstr:strpos(FixedPacket, "\r\n.\r\n") of
						0 ->
							%io:format("received ~B bytes; size is now ~p~n", [RecvSize, Size + size(Packet)]),
							%io:format("memory usage: ~p~n", [erlang:process_info(self(), memory)]),
							receive_data([FixedPacket | Acc], Transport, Socket, RecvSize, Size + byte_size(FixedPacket), MaxSize, Session, Options);
						Index ->
							String = binstr:substr(FixedPacket, 1, Index - 1),
							Rest = binstr:substr(FixedPacket, Index+5),
							%io:format("memory usage before flattening: ~p~n", [erlang:process_info(self(), memory)]),
							Result = list_to_binary(lists:reverse([String | Acc])),
							%io:format("memory usage after flattening: ~p~n", [erlang:process_info(self(), memory)]),
							Session ! {receive_data, Result, Rest}
					end
			end;
		{error, timeout} when RecvSize =:= 0, length(Acc) > 1 ->
			% check that we didn't accidentally receive a \r\n.\r\n split across 2 receives
			[A, B | Acc2] = Acc,
			Packet = list_to_binary([B, A]),
			case binstr:strpos(Packet, "\r\n.\r\n") of
				0 ->
					% uh-oh
					%io:format("no data on socket, and no DATA terminator, retrying ~p~n", [Session]),
					% eventually we'll either get data or a different error, just keep retrying
					receive_data(Acc, Transport, Socket, 0, Size, MaxSize, Session, Options);
				Index ->
					String = binstr:substr(Packet, 1, Index - 1),
					Rest = binstr:substr(Packet, Index+5),
					%io:format("memory usage before flattening: ~p~n", [erlang:process_info(self(), memory)]),
					Result = list_to_binary(lists:reverse([String | Acc2])),
					%io:format("memory usage after flattening: ~p~n", [erlang:process_info(self(), memory)]),
					Session ! {receive_data, Result, Rest}
			end;
		{error, timeout} ->
			receive_data(Acc, Transport, Socket, 0, Size, MaxSize, Session, Options);
		{error, Reason} ->
			io:format("receive error: ~p~n", [Reason]),
			exit(receive_error)
	end.

check_for_bare_crlf(Bin, Offset) ->
	case {re:run(Bin, "(?<!\r)\n", [{capture, none}, {offset, Offset}]), re:run(Bin, "\r(?!\n)", [{capture, none}, {offset, Offset}])}  of
		{match, _} -> true;
		{_, match} -> true;
		_ -> false
	end.

fix_bare_crlf(Bin, Offset) ->
	Options = [{offset, Offset}, {return, binary}, global],
	re:replace(re:replace(Bin, "(?<!\r)\n", "\r\n", Options), "\r(?!\n)", "\r\n", Options).

strip_bare_crlf(Bin, Offset) ->
	Options = [{offset, Offset}, {return, binary}, global],
	re:replace(re:replace(Bin, "(?<!\r)\n", "", Options), "\r(?!\n)", "", Options).

check_bare_crlf(Binary, _, ignore, _) ->
	Binary;
check_bare_crlf(<<$\n, _Rest/binary>> = Bin, Prev, Op, Offset) when byte_size(Prev) > 0, Offset == 0 ->
	% check if last character of previous was a CR
	Lastchar = binstr:substr(Prev, -1),
	case Lastchar of
		<<"\r">> ->
			% okay, check again for the rest
			check_bare_crlf(Bin, <<>>, Op, 1);
		_ when Op == false -> % not fixing or ignoring them
			error;
		_ ->
			% no dice
			check_bare_crlf(Bin, <<>>, Op, 0)
	end;
check_bare_crlf(Binary, _Prev, Op, Offset) ->
	Last = binstr:substr(Binary, -1),
	% is the last character a CR?
	case Last of
		<<"\r">> ->
			% okay, the last character is a CR, we have to assume the next packet contains the corresponding LF
			NewBin = binstr:substr(Binary, 1, byte_size(Binary) -1),
			case check_for_bare_crlf(NewBin, Offset) of
				true when Op == fix ->
					list_to_binary([fix_bare_crlf(NewBin, Offset), "\r"]);
				true when Op == strip ->
					list_to_binary([strip_bare_crlf(NewBin, Offset), "\r"]);
				true ->
					error;
				false ->
					Binary
			end;
		_ ->
			case check_for_bare_crlf(Binary, Offset) of
				true when Op == fix ->
					fix_bare_crlf(Binary, Offset);
				true when Op == strip ->
					strip_bare_crlf(Binary, Offset);
				true ->
					error;
				false ->
					Binary
			end
	end.

send(#state{transport = Transport, socket = Sock}, Data) ->
    ok = Transport:send(Sock, Data).

setopts(#state{transport = Transport, socket = Sock}, Opts) ->
    ok = Transport:setopts(Sock, Opts).

hostname(Opts) ->
    proplists:get_value(hostname, Opts, smtp_util:guess_FQDN()).    

get_proto(ranch_tcp) -> tcp;
get_proto(ranch_ssl) -> ssl.

-ifdef(TEST).
parse_encoded_address_test_() ->
	[
		{"Valid addresses should parse",
			fun() ->
					?assertEqual({<<"God@heaven.af.mil">>, <<>>}, parse_encoded_address(<<"<God@heaven.af.mil>">>)),
					?assertEqual({<<"God@heaven.af.mil">>, <<>>}, parse_encoded_address(<<"<\\God@heaven.af.mil>">>)),
					?assertEqual({<<"God@heaven.af.mil">>, <<>>}, parse_encoded_address(<<"<\"God\"@heaven.af.mil>">>)),
					?assertEqual({<<"God@heaven.af.mil">>, <<>>}, parse_encoded_address(<<"<@gateway.af.mil,@uucp.local:\"\\G\\o\\d\"@heaven.af.mil>">>)),
					?assertEqual({<<"God2@heaven.af.mil">>, <<>>}, parse_encoded_address(<<"<God2@heaven.af.mil>">>)),
					?assertEqual({<<"God+extension@heaven.af.mil">>, <<>>}, parse_encoded_address(<<"<God+extension@heaven.af.mil>">>)),
					?assertEqual({<<"God~*$@heaven.af.mil">>, <<>>}, parse_encoded_address(<<"<God~*$@heaven.af.mil>">>))
			end
		},
		{"Addresses that are sorta valid should parse",
			fun() ->
					?assertEqual({<<"God@heaven.af.mil">>, <<>>}, parse_encoded_address(<<"God@heaven.af.mil">>)),
					?assertEqual({<<"God@heaven.af.mil">>, <<>>}, parse_encoded_address(<<"God@heaven.af.mil ">>)),
					?assertEqual({<<"God@heaven.af.mil">>, <<>>}, parse_encoded_address(<<" God@heaven.af.mil ">>)),
					?assertEqual({<<"God@heaven.af.mil">>, <<>>}, parse_encoded_address(<<" <God@heaven.af.mil> ">>))
			end
		},
		{"Addresses containing unescaped <> that aren't at start/end should fail",
			fun() ->
					?assertEqual(error, parse_encoded_address(<<"<<">>)),
					?assertEqual(error, parse_encoded_address(<<"<God<@heaven.af.mil>">>))
			end
		},
		{"Address that begins with < but doesn't end with a > should fail",
			fun() ->
					?assertEqual(error, parse_encoded_address(<<"<God@heaven.af.mil">>)),
					?assertEqual(error, parse_encoded_address(<<"<God@heaven.af.mil ">>))
			end
		},
		{"Address that begins without < but ends with a > should fail",
			fun() ->
					?assertEqual(error, parse_encoded_address(<<"God@heaven.af.mil>">>))
			end
		},
		{"Address longer than 320 characters should fail",
			fun() ->
					MegaAddress = list_to_binary(lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++ "@" ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122) ++ lists:seq(97, 122)),
					?assertEqual(error, parse_encoded_address(MegaAddress))
			end
		},
		{"Address with an invalid route should fail",
			fun() ->
					?assertEqual(error, parse_encoded_address(<<"<@gateway.af.mil God@heaven.af.mil>">>))
			end
		},
		{"Empty addresses should parse OK",
			fun() ->
					?assertEqual({<<>>, <<>>}, parse_encoded_address(<<"<>">>)),
					?assertEqual({<<>>, <<>>}, parse_encoded_address(<<" <> ">>))
			end
		},
		{"Completely empty addresses are an error",
			fun() ->
					?assertEqual(error, parse_encoded_address(<<"">>)),
					?assertEqual(error, parse_encoded_address(<<" ">>))
			end
		},
		{"addresses with trailing parameters should return the trailing parameters",
			fun() ->
					?assertEqual({<<"God@heaven.af.mil">>, <<"SIZE=100 BODY=8BITMIME">>}, parse_encoded_address(<<"<God@heaven.af.mil> SIZE=100 BODY=8BITMIME">>))
			end
		}
	].

parse_request_test_() ->
	[
		{"Parsing normal SMTP requests",
			fun() ->
					?assertEqual({<<"HELO">>, <<>>}, parse_request(<<"HELO\r\n">>)),
					?assertEqual({<<"EHLO">>, <<"hell.af.mil">>}, parse_request(<<"EHLO hell.af.mil\r\n">>)),
					?assertEqual({<<"MAIL">>, <<"FROM:God@heaven.af.mil">>}, parse_request(<<"MAIL FROM:God@heaven.af.mil">>))
			end
		},
		{"Verbs should be uppercased",
			fun() ->
					?assertEqual({<<"HELO">>, <<"hell.af.mil">>}, parse_request(<<"helo hell.af.mil">>))
			end
		},
		{"Leading and trailing spaces are removed",
			fun() ->
					?assertEqual({<<"HELO">>, <<"hell.af.mil">>}, parse_request(<<" helo   hell.af.mil           ">>))
			end
		},
		{"Blank lines are blank",
			fun() ->
					?assertEqual({<<>>, <<>>}, parse_request(<<"">>))
			end
		}
	].

smtp_session_test_() ->
	{foreach,
		local,
		fun() ->
				{ok, Pid} = gen_smtp_server:start(
                              smtp_server_example,
                              [{sessionoptions, [{hostname, "localhost"}]},
                               {port, 9876}]),
				{ok, CSock} = smtp_socket:connect(tcp, "localhost", 9876),
				{CSock, Pid}
		end,
		fun({CSock, _Pid}) ->
                gen_smtp_server:stop(gen_smtp_server),
				smtp_socket:close(CSock)
		end,
		[fun({CSock, _Pid}) ->
					{"A new connection should get a banner",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> ok end,
								?assertMatch("220 localhost"++_Stuff,  Packet)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"A correct response to HELO",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "HELO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250 localhost\r\n",  Packet2)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"An error in response to an invalid HELO",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "HELO\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("501 Syntax: HELO hostname\r\n",  Packet2)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"A rejected HELO",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "HELO invalid\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("554 invalid hostname\r\n",  Packet2)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"A rejected EHLO",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO invalid\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("554 invalid hostname\r\n",  Packet2)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"EHLO response",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F) ->
										receive
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F);
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												ok;
											{tcp, CSock, _R} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(ok, Foo(Foo))
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"Unsupported AUTH PLAIN",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F) ->
										receive
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F);
											{tcp, CSock, "250"++_Packet3} ->
												smtp_socket:active_once(CSock),
												ok;
											{tcp, CSock, _R} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(ok, Foo(Foo)),
								smtp_socket:send(CSock, "AUTH PLAIN\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("502 Error: AUTH not implemented\r\n",  Packet4)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"Sending DATA",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "HELO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250 localhost\r\n",  Packet2),
								smtp_socket:send(CSock, "MAIL FROM: <user@somehost.com>\r\n"),
								receive {tcp, CSock, Packet3} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250 "++_, Packet3),
								smtp_socket:send(CSock, "RCPT TO: <user@otherhost.com>\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250 "++_, Packet4),
								smtp_socket:send(CSock, "DATA\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("354 "++_, Packet5),
								smtp_socket:send(CSock, "Subject: tls message\r\n"),
								smtp_socket:send(CSock, "To: <user@otherhost>\r\n"),
								smtp_socket:send(CSock, "From: <user@somehost.com>\r\n"),
								smtp_socket:send(CSock, "\r\n"),
								smtp_socket:send(CSock, "message body"),
								smtp_socket:send(CSock, "\r\n.\r\n"),
								receive {tcp, CSock, Packet6} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250 queued as"++_, Packet6)
						end
					}
			end,
%			fun({CSock, _Pid}) ->
%					{"Sending DATA with a bare newline",
%						fun() ->
%								smtp_socket:active_once(CSock),
%								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("220 localhost"++_Stuff,  Packet),
%								smtp_socket:send(CSock, "HELO somehost.com\r\n"),
%								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("250 localhost\r\n",  Packet2),
%								smtp_socket:send(CSock, "MAIL FROM: <user@somehost.com>\r\n"),
%								receive {tcp, CSock, Packet3} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("250 "++_, Packet3),
%								smtp_socket:send(CSock, "RCPT TO: <user@otherhost.com>\r\n"),
%								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("250 "++_, Packet4),
%								smtp_socket:send(CSock, "DATA\r\n"),
%								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("354 "++_, Packet5),
%								smtp_socket:send(CSock, "Subject: tls message\r\n"),
%								smtp_socket:send(CSock, "To: <user@otherhost>\r\n"),
%								smtp_socket:send(CSock, "From: <user@somehost.com>\r\n"),
%								smtp_socket:send(CSock, "\r\n"),
%								smtp_socket:send(CSock, "this\r\n"),
%								smtp_socket:send(CSock, "body\r\n"),
%								smtp_socket:send(CSock, "has\r\n"),
%								smtp_socket:send(CSock, "a\r\n"),
%								smtp_socket:send(CSock, "bare\n"),
%								smtp_socket:send(CSock, "newline\r\n"),
%								smtp_socket:send(CSock, "\r\n.\r\n"),
%								receive {tcp, CSock, Packet6} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("451 "++_, Packet6),
%						end
%					}
%			end,
			%fun({CSock, _Pid}) ->
%					{"Sending DATA with a bare CR",
%						fun() ->
%								smtp_socket:active_once(CSock),
%								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("220 localhost"++_Stuff,  Packet),
%								smtp_socket:send(CSock, "HELO somehost.com\r\n"),
%								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("250 localhost\r\n",  Packet2),
%								smtp_socket:send(CSock, "MAIL FROM: <user@somehost.com>\r\n"),
%								receive {tcp, CSock, Packet3} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("250 "++_, Packet3),
%								smtp_socket:send(CSock, "RCPT TO: <user@otherhost.com>\r\n"),
%								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("250 "++_, Packet4),
%								smtp_socket:send(CSock, "DATA\r\n"),
%								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("354 "++_, Packet5),
%								smtp_socket:send(CSock, "Subject: tls message\r\n"),
%								smtp_socket:send(CSock, "To: <user@otherhost>\r\n"),
%								smtp_socket:send(CSock, "From: <user@somehost.com>\r\n"),
%								smtp_socket:send(CSock, "\r\n"),
%								smtp_socket:send(CSock, "this\r\n"),
%								smtp_socket:send(CSock, "\rbody\r\n"),
%								smtp_socket:send(CSock, "has\r\n"),
%								smtp_socket:send(CSock, "a\r\n"),
%								smtp_socket:send(CSock, "bare\r"),
%								smtp_socket:send(CSock, "CR\r\n"),
%								smtp_socket:send(CSock, "\r\n.\r\n"),
%								receive {tcp, CSock, Packet6} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("451 "++_, Packet6),
%						end
%					}
%			end,

%			fun({CSock, _Pid}) ->
%					{"Sending DATA with a bare newline in the headers",
%						fun() ->
%								smtp_socket:active_once(CSock),
%								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("220 localhost"++_Stuff,  Packet),
%								smtp_socket:send(CSock, "HELO somehost.com\r\n"),
%								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("250 localhost\r\n",  Packet2),
%								smtp_socket:send(CSock, "MAIL FROM: <user@somehost.com>\r\n"),
%								receive {tcp, CSock, Packet3} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("250 "++_, Packet3),
%								smtp_socket:send(CSock, "RCPT TO: <user@otherhost.com>\r\n"),
%								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("250 "++_, Packet4),
%								smtp_socket:send(CSock, "DATA\r\n"),
%								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("354 "++_, Packet5),
%								smtp_socket:send(CSock, "Subject: tls message\r\n"),
%								smtp_socket:send(CSock, "To: <user@otherhost>\n"),
%								smtp_socket:send(CSock, "From: <user@somehost.com>\r\n"),
%								smtp_socket:send(CSock, "\r\n"),
%								smtp_socket:send(CSock, "this\r\n"),
%								smtp_socket:send(CSock, "body\r\n"),
%								smtp_socket:send(CSock, "has\r\n"),
%								smtp_socket:send(CSock, "no\r\n"),
%								smtp_socket:send(CSock, "bare\r\n"),
%								smtp_socket:send(CSock, "newlines\r\n"),
%								smtp_socket:send(CSock, "\r\n.\r\n"),
%								receive {tcp, CSock, Packet6} -> smtp_socket:active_once(CSock) end,
%								?assertMatch("451 "++_, Packet6),
%						end
%					}
%			end,
			fun({CSock, _Pid}) ->
					{"Sending DATA with bare newline on first line of body",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "HELO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250 localhost\r\n",  Packet2),
								smtp_socket:send(CSock, "MAIL FROM: <user@somehost.com>\r\n"),
								receive {tcp, CSock, Packet3} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250 "++_, Packet3),
								smtp_socket:send(CSock, "RCPT TO: <user@otherhost.com>\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250 "++_, Packet4),
								smtp_socket:send(CSock, "DATA\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("354 "++_, Packet5),
								smtp_socket:send(CSock, "Subject: tls message\r\n"),
								smtp_socket:send(CSock, "To: <user@otherhost>\n"),
								smtp_socket:send(CSock, "From: <user@somehost.com>\r\n"),
								smtp_socket:send(CSock, "\r\n"),
								smtp_socket:send(CSock, "this\n"),
								smtp_socket:send(CSock, "body\r\n"),
								smtp_socket:send(CSock, "has\r\n"),
								smtp_socket:send(CSock, "no\r\n"),
								smtp_socket:send(CSock, "bare\r\n"),
								smtp_socket:send(CSock, "newlines\r\n"),
								smtp_socket:send(CSock, "\r\n.\r\n"),
								receive {tcp, CSock, Packet6} -> smtp_socket:active_once(CSock) end,
								?assertMatch("451 "++_, Packet6)
						end
					}
			end

		]
	}.

smtp_session_auth_test_() ->
	{foreach,
		local,
		fun() ->
				{ok, Pid} = gen_smtp_server:start(
                              smtp_server_example,
                              [{sessionoptions,
                                [{hostname, "localhost"},
                                 {callbackoptions, [{auth, true}]}]},
                               {port, 9876}]),
				{ok, CSock} = smtp_socket:connect(tcp, "localhost", 9876),
				{CSock, Pid}
		end,
		fun({CSock, _Pid}) ->
                gen_smtp_server:stop(gen_smtp_server),
				smtp_socket:close(CSock)
		end,
		[fun({CSock, _Pid}) ->
					{"EHLO response includes AUTH",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false))
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"AUTH before EHLO is error",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "AUTH CRAZY\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("503 "++_,  Packet4)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"Unknown authentication type",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "AUTH CRAZY\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("504 Unrecognized authentication type\r\n",  Packet4)
						end
					}
			end,

			fun({CSock, _Pid}) ->
					{"A successful AUTH PLAIN",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "AUTH PLAIN\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("334\r\n",  Packet4),
								String = binary_to_list(base64:encode("\0username\0PaSSw0rd")),
								smtp_socket:send(CSock, String++"\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("235 Authentication successful.\r\n",  Packet5)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"A successful AUTH PLAIN with an identity",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "AUTH PLAIN\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("334\r\n",  Packet4),
								String = binary_to_list(base64:encode("username\0username\0PaSSw0rd")),
								smtp_socket:send(CSock, String++"\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("235 Authentication successful.\r\n",  Packet5)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"A successful immediate AUTH PLAIN",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								String = binary_to_list(base64:encode("\0username\0PaSSw0rd")),
								smtp_socket:send(CSock, "AUTH PLAIN "++String++"\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("235 Authentication successful.\r\n",  Packet5)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"A successful immediate AUTH PLAIN with an identity",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _R} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								String = binary_to_list(base64:encode("username\0username\0PaSSw0rd")),
								smtp_socket:send(CSock, "AUTH PLAIN "++String++"\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("235 Authentication successful.\r\n",  Packet5)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"An unsuccessful immediate AUTH PLAIN",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								String = binary_to_list(base64:encode("username\0username\0PaSSw0rd2")),
								smtp_socket:send(CSock, "AUTH PLAIN "++String++"\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("535 Authentication failed.\r\n",  Packet5)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"An unsuccessful AUTH PLAIN",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "AUTH PLAIN\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("334\r\n",  Packet4),
								String = binary_to_list(base64:encode("\0username\0NotThePassword")),
								smtp_socket:send(CSock, String++"\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("535 Authentication failed.\r\n",  Packet5)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"A successful AUTH LOGIN",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "AUTH LOGIN\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("334 VXNlcm5hbWU6\r\n",  Packet4),
								String = binary_to_list(base64:encode("username")),
								smtp_socket:send(CSock, String++"\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("334 UGFzc3dvcmQ6\r\n",  Packet5),
								PString = binary_to_list(base64:encode("PaSSw0rd")),
								smtp_socket:send(CSock, PString++"\r\n"),
								receive {tcp, CSock, Packet6} -> smtp_socket:active_once(CSock) end,
								?assertMatch("235 Authentication successful.\r\n",  Packet6)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"An unsuccessful AUTH LOGIN",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "AUTH LOGIN\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("334 VXNlcm5hbWU6\r\n",  Packet4),
								String = binary_to_list(base64:encode("username2")),
								smtp_socket:send(CSock, String++"\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("334 UGFzc3dvcmQ6\r\n",  Packet5),
								PString = binary_to_list(base64:encode("PaSSw0rd")),
								smtp_socket:send(CSock, PString++"\r\n"),
								receive {tcp, CSock, Packet6} -> smtp_socket:active_once(CSock) end,
								?assertMatch("535 Authentication failed.\r\n",  Packet6)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"A successful AUTH CRAM-MD5",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "AUTH CRAM-MD5\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("334 "++_,  Packet4),

								["334", Seed64] = string:tokens(smtp_util:trim_crlf(Packet4), " "),
								Seed = base64:decode_to_string(Seed64),
								Digest = smtp_util:compute_cram_digest("PaSSw0rd", Seed),
								String = binary_to_list(base64:encode(list_to_binary(["username ", Digest]))),
								smtp_socket:send(CSock, String++"\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("235 Authentication successful.\r\n",  Packet5)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"An unsuccessful AUTH CRAM-MD5",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 AUTH"++_Packet3} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "AUTH CRAM-MD5\r\n"),
								receive {tcp, CSock, Packet4} -> smtp_socket:active_once(CSock) end,
								?assertMatch("334 "++_,  Packet4),

								["334", Seed64] = string:tokens(smtp_util:trim_crlf(Packet4), " "),
								Seed = base64:decode_to_string(Seed64),
								Digest = smtp_util:compute_cram_digest("Passw0rd", Seed),
								String = binary_to_list(base64:encode(list_to_binary(["username ", Digest]))),
								smtp_socket:send(CSock, String++"\r\n"),
								receive {tcp, CSock, Packet5} -> smtp_socket:active_once(CSock) end,
								?assertMatch("535 Authentication failed.\r\n",  Packet5)
						end
					}
			end
		]
	}.

smtp_session_tls_test_() ->
	{foreach,
		local,
		fun() ->
				{ok, Pid} = gen_smtp_server:start(
                              smtp_server_example,
                              [{sessionoptions,
                                [{keyfile, "test/fixtures/server.key"},
                                 {certfile, "test/fixtures/server.crt"},
                                 {hostname, "localhost"},
                                 {callbackoptions, [{auth, true}]}]},
                               {port, 9876}]),
				{ok, CSock} = smtp_socket:connect(tcp, "localhost", 9876),
				{CSock, Pid}
		end,
		fun({CSock, _Pid}) ->
                gen_smtp_server:stop(gen_smtp_server),
				smtp_socket:close(CSock)
		end,
		[fun({CSock, _Pid}) ->
					{"EHLO response includes STARTTLS",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false))
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"STARTTLS does a SSL handshake",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "STARTTLS\r\n"),
								receive {tcp, CSock, Packet4} -> ok end,
								?assertMatch("220 "++_,  Packet4),
								Result = smtp_socket:to_ssl_client(CSock),
								?assertMatch({ok, _Socket}, Result),
								{ok, _Socket} = Result
								%smtp_socket:active_once(Socket),
								%ssl:send(Socket, "EHLO somehost.com\r\n"),
								%receive {ssl, Socket, Packet5} -> smtp_socket:active_once(Socket) end,
								%?assertEqual("Foo", Packet5),
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"After STARTTLS, EHLO doesn't report STARTTLS",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "STARTTLS\r\n"),
								receive {tcp, CSock, Packet4} -> ok end,
								?assertMatch("220 "++_,  Packet4),
								Result = smtp_socket:to_ssl_client(CSock),
								?assertMatch({ok, _Socket}, Result),
								{ok, Socket} = Result,
								smtp_socket:active_once(Socket),
								smtp_socket:send(Socket, "EHLO somehost.com\r\n"),
								receive {ssl, Socket, Packet5} -> smtp_socket:active_once(Socket) end,
								?assertMatch("250-localhost\r\n",  Packet5),
								Bar = fun(F, Acc) ->
										receive
											{ssl, Socket, "250-STARTTLS"++_} ->
												smtp_socket:active_once(Socket),
												F(F, true);
											{ssl, Socket, "250-"++_} ->
												smtp_socket:active_once(Socket),
												F(F, Acc);
											{ssl, Socket, "250 STARTTLS"++_} ->
												smtp_socket:active_once(Socket),
												true;
											{ssl, Socket, "250 "++_} ->
												smtp_socket:active_once(Socket),
												Acc;
											{ssl, Socket, _} ->
												smtp_socket:active_once(Socket),
												error
										end
								end,
								?assertEqual(false, Bar(Bar, false))
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"After STARTTLS, re-negotiating STARTTLS is an error",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "STARTTLS\r\n"),
								receive {tcp, CSock, Packet4} -> ok end,
								?assertMatch("220 "++_,  Packet4),
								Result = smtp_socket:to_ssl_client(CSock),
								?assertMatch({ok, _Socket}, Result),
								{ok, Socket} = Result,
								smtp_socket:active_once(Socket),
								smtp_socket:send(Socket, "EHLO somehost.com\r\n"),
								receive {ssl, Socket, Packet5} -> smtp_socket:active_once(Socket) end,
								?assertMatch("250-localhost\r\n",  Packet5),
								Bar = fun(F, Acc) ->
										receive
											{ssl, Socket, "250-STARTTLS"++_} ->
												smtp_socket:active_once(Socket),
												F(F, true);
											{ssl, Socket, "250-"++_} ->
												smtp_socket:active_once(Socket),
												F(F, Acc);
											{ssl, Socket, "250 STARTTLS"++_} ->
												smtp_socket:active_once(Socket),
												true;
											{ssl, Socket, "250 "++_} ->
												smtp_socket:active_once(Socket),
												Acc;
											{ssl, Socket, _} ->
												smtp_socket:active_once(Socket),
												error
										end
								end,
								?assertEqual(false, Bar(Bar, false)),
								smtp_socket:send(Socket, "STARTTLS\r\n"),
								receive {ssl, Socket, Packet6} -> smtp_socket:active_once(Socket) end,
								?assertMatch("500 "++_, Packet6)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"STARTTLS can't take any parameters",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "STARTTLS foo\r\n"),
								receive {tcp, CSock, Packet4} -> ok end,
								?assertMatch("501 "++_,  Packet4)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"Negotiating STARTTLS twice is an error",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, _Packet} -> smtp_socket:active_once(CSock) end,
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, _Packet2} -> smtp_socket:active_once(CSock) end,
								ReadExtensions = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, ReadExtensions(ReadExtensions, false)),
								smtp_socket:send(CSock, "STARTTLS\r\n"),
								receive {tcp, CSock, _} -> ok end,
								{ok, Socket} = smtp_socket:to_ssl_client(CSock),
								smtp_socket:active_once(Socket),
								smtp_socket:send(Socket, "EHLO somehost.com\r\n"),
								receive {ssl, Socket, PacketN} -> smtp_socket:active_once(Socket) end,
								?assertMatch("250-localhost\r\n",  PacketN),
								Bar = fun(F, Acc) ->
										receive
											{ssl, Socket, "250-STARTTLS"++_} ->
												smtp_socket:active_once(Socket),
												F(F, true);
											{ssl, Socket, "250-"++_} ->
												smtp_socket:active_once(Socket),
												F(F, Acc);
											{ssl, Socket, "250 STARTTLS"++_} ->
												smtp_socket:active_once(Socket),
												true;
											{ssl, Socket, "250 "++_} ->
												smtp_socket:active_once(Socket),
												Acc;
											{tcp, Socket, _} ->
												smtp_socket:active_once(Socket),
												error
										end
								end,
								?assertEqual(false, Bar(Bar, false)),
								smtp_socket:send(Socket, "STARTTLS\r\n"),
								receive {ssl, Socket, Packet6} -> smtp_socket:active_once(Socket) end,
								?assertMatch("500 "++_,  Packet6)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"STARTTLS can't take any parameters",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, Packet} -> smtp_socket:active_once(CSock) end,
								?assertMatch("220 localhost"++_Stuff,  Packet),
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, Packet2} -> smtp_socket:active_once(CSock) end,
								?assertMatch("250-localhost\r\n",  Packet2),
								Foo = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, Foo(Foo, false)),
								smtp_socket:send(CSock, "STARTTLS foo\r\n"),
								receive {tcp, CSock, Packet4} -> ok end,
								?assertMatch("501 "++_,  Packet4)
						end
					}
			end,
			fun({CSock, _Pid}) ->
					{"After STARTTLS, message is received by server",
						fun() ->
								smtp_socket:active_once(CSock),
								receive {tcp, CSock, _Packet} -> smtp_socket:active_once(CSock) end,
								smtp_socket:send(CSock, "EHLO somehost.com\r\n"),
								receive {tcp, CSock, _Packet2} -> smtp_socket:active_once(CSock) end,
								ReadExtensions = fun(F, Acc) ->
										receive
											{tcp, CSock, "250-STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												F(F, true);
											{tcp, CSock, "250-"++_Packet3} ->
												smtp_socket:active_once(CSock),
												F(F, Acc);
											{tcp, CSock, "250 STARTTLS"++_} ->
												smtp_socket:active_once(CSock),
												true;
											{tcp, CSock, "250 "++_Packet3} ->
												smtp_socket:active_once(CSock),
												Acc;
											{tcp, CSock, _} ->
												smtp_socket:active_once(CSock),
												error
										end
								end,
								?assertEqual(true, ReadExtensions(ReadExtensions, false)),
								smtp_socket:send(CSock, "STARTTLS\r\n"),
								receive {tcp, CSock, _} -> ok end,
								{ok, Socket} = smtp_socket:to_ssl_client(CSock),
								smtp_socket:active_once(Socket),
								smtp_socket:send(Socket, "EHLO somehost.com\r\n"),
								ReadSSLExtensions = fun(F, Acc) ->
										receive
											{ssl, Socket, "250-"++_Rest} ->
												smtp_socket:active_once(Socket),
												F(F, Acc);
											{ssl, Socket, "250 "++_} ->
												smtp_socket:active_once(Socket),
												true;
											{ssl, Socket, _R} ->
												smtp_socket:active_once(Socket),
												error
										end
								end,
								?assertEqual(true, ReadSSLExtensions(ReadSSLExtensions, false)),
								smtp_socket:send(Socket, "MAIL FROM: <user@somehost.com>\r\n"),
								receive {ssl, Socket, Packet4} -> smtp_socket:active_once(Socket) end,
								?assertMatch("250 "++_, Packet4),
								smtp_socket:send(Socket, "RCPT TO: <user@otherhost.com>\r\n"),
								receive {ssl, Socket, Packet5} -> smtp_socket:active_once(Socket) end,
								?assertMatch("250 "++_, Packet5),
								smtp_socket:send(Socket, "DATA\r\n"),
								receive {ssl, Socket, Packet6} -> smtp_socket:active_once(Socket) end,
								?assertMatch("354 "++_, Packet6),
								smtp_socket:send(Socket, "Subject: tls message\r\n"),
								smtp_socket:send(Socket, "To: <user@otherhost>\r\n"),
								smtp_socket:send(Socket, "From: <user@somehost.com>\r\n"),
								smtp_socket:send(Socket, "\r\n"),
								smtp_socket:send(Socket, "message body"),
								smtp_socket:send(Socket, "\r\n.\r\n"),
								receive {ssl, Socket, Packet7} -> smtp_socket:active_once(Socket) end,
								?assertMatch("250 "++_, Packet7)
						end
					}
			end
		]
	}.

stray_newline_test_() ->
	[
		{"Error out by default",
			fun() ->
					?assertEqual(<<"foo">>, check_bare_crlf(<<"foo">>, <<>>, false, 0)),
					?assertEqual(error, check_bare_crlf(<<"foo\n">>, <<>>, false, 0)),
					?assertEqual(error, check_bare_crlf(<<"fo\ro\n">>, <<>>, false, 0)),
					?assertEqual(error, check_bare_crlf(<<"fo\ro\n\r">>, <<>>, false, 0)),
					?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"foo\r\n">>, <<>>, false, 0)),
					?assertEqual(<<"foo\r">>, check_bare_crlf(<<"foo\r">>, <<>>, false, 0))
			end
		},
		{"Fixing them should work",
			fun() ->
					?assertEqual(<<"foo">>, check_bare_crlf(<<"foo">>, <<>>, fix, 0)),
					?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"foo\n">>, <<>>, fix, 0)),
					?assertEqual(<<"fo\r\no\r\n">>, check_bare_crlf(<<"fo\ro\n">>, <<>>, fix, 0)),
					?assertEqual(<<"fo\r\no\r\n\r">>, check_bare_crlf(<<"fo\ro\n\r">>, <<>>, fix, 0)),
					?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"foo\r\n">>, <<>>, fix, 0))
			end
		},
		{"Stripping them should work",
			fun() ->
					?assertEqual(<<"foo">>, check_bare_crlf(<<"foo">>, <<>>, strip, 0)),
					?assertEqual(<<"foo">>, check_bare_crlf(<<"fo\ro\n">>, <<>>, strip, 0)),
					?assertEqual(<<"foo\r">>, check_bare_crlf(<<"fo\ro\n\r">>, <<>>, strip, 0)),
					?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"foo\r\n">>, <<>>, strip, 0))
			end
		},
		{"Ignoring them should work",
			fun() ->
					?assertEqual(<<"foo">>, check_bare_crlf(<<"foo">>, <<>>, ignore, 0)),
					?assertEqual(<<"fo\ro\n">>, check_bare_crlf(<<"fo\ro\n">>, <<>>, ignore, 0)),
					?assertEqual(<<"fo\ro\n\r">>, check_bare_crlf(<<"fo\ro\n\r">>, <<>>, ignore, 0)),
					?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"foo\r\n">>, <<>>, ignore, 0))
			end
		},
		{"Leading bare LFs should check the previous line",
			fun() ->
					?assertEqual(<<"\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r">>, false, 0)),
					?assertEqual(<<"\r\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r\n">>, fix, 0)),
					?assertEqual(<<"\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r">>, fix, 0)),
					?assertEqual(<<"foo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r\n">>, strip, 0)),
					?assertEqual(<<"\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r">>, strip, 0)),
					?assertEqual(<<"\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r\n">>, ignore, 0)),
					?assertEqual(error, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r\n">>, false, 0)),
					?assertEqual(<<"\nfoo\r\n">>, check_bare_crlf(<<"\nfoo\r\n">>, <<"bar\r">>, false, 0))
			end
		}
	].


-endif.
