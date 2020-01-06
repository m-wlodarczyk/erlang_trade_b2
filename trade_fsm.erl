-module(trade_fsm).

-behaviour(gen_fsm).

%% public API
-export([accept_bidding/1, accept_trade/1, bidding/2,
	 cancel/1, make_offer/2, make_price/2, ready/1,
	 retract_offer/2, start/1, start_link/1, trade/2]).

%% gen_fsm callbacks
-export([bid/2, bid/3, code_change/4, handle_event/3,
	 handle_info/3, handle_sync_event/4, idle/2, idle/3,
	 idle_wait/2, idle_wait/3, init/1, negotiate/2,
	 negotiate/3, negotiate_wait/2, negotiate_wait/3,
	 ready/2, ready/3, terminate/3, wait/2]).

         % custom state names

-record(state,
	{name = "", role = "", item = "", price = -1, other,
	 ownitems = [], otheritems = [], monitor, from}).

%%% PUBLIC API
start(Name) -> gen_fsm:start(?MODULE, [Name], []).

start_link(Name) ->
    gen_fsm:start_link(?MODULE, [Name], []).

%% ask for a begin session. Returns when/if the other accepts
trade(OwnPid, OtherPid) ->
    gen_fsm:sync_send_event(OwnPid, {negotiate, OtherPid},
			    30000).

bidding(OwnPid, OtherPid) ->
    gen_fsm:sync_send_event(OwnPid, {bid, OtherPid}, 30000).

%% Accept someone's trade offer.
accept_trade(OwnPid) ->
    gen_fsm:sync_send_event(OwnPid, accept_negotiate).

accept_bidding(OwnPid) ->
    gen_fsm:sync_send_event(OwnPid, accept_bid).

%% Send an item on the table to be traded
make_offer(OwnPid, Item) ->
    gen_fsm:send_event(OwnPid, {make_offer, Item}).

make_price(OwnPid, Price) ->
    gen_fsm:send_event(OwnPid, {make_price, Price}).

%% Cancel trade offer
retract_offer(OwnPid, Item) ->
    gen_fsm:send_event(OwnPid, {retract_offer, Item}).

%% Mention that you're ready for a trade. When the other
%% player also declares being ready, the trade is done
ready(OwnPid) ->
    gen_fsm:sync_send_event(OwnPid, ready, infinity).

%% Cancel the transaction.
cancel(OwnPid) ->
    gen_fsm:sync_send_all_state_event(OwnPid, cancel).

%%% CLIENT-TO-CLIENT API
%% These calls are only listed for the gen_fsm to call
%% among themselves
%% All calls are asynchronous to avoid deadlocks

%% Ask the other FSM for a trade session
ask_negotiate(OtherPid, OwnPid) ->
    gen_fsm:send_event(OtherPid, {ask_negotiate, OwnPid}).

ask_bid(OtherPid, OwnPid) ->
    gen_fsm:send_event(OtherPid, {ask_bid, OwnPid}).

%% Forward the client message accepting the transaction
accept_negotiate(OtherPid, OwnPid) ->
    gen_fsm:send_event(OtherPid,
		       {accept_negotiate, OwnPid}).

accept_bid(OtherPid, OwnPid) ->
    gen_fsm:send_event(OtherPid, {accept_bid, OwnPid}).

%% forward a client's offer
do_offer(OtherPid, Item) ->
    gen_fsm:send_event(OtherPid, {do_offer, Item}).

%% forward a client's offer price
do_price(OtherPid, Price) ->
    gen_fsm:send_event(OtherPid, {do_price, Price}).

%% forward a client's offer cancellation
undo_offer(OtherPid, Item) ->
    gen_fsm:send_event(OtherPid, {undo_offer, Item}).

%% Ask the other side if he's ready to trade.
are_you_ready(OtherPid) ->
    gen_fsm:send_event(OtherPid, are_you_ready).

%% Reply that the side is not ready to trade
%% i.e. is not in 'wait' state.
not_yet(OtherPid) ->
    gen_fsm:send_event(OtherPid, not_yet).

%% Tells the other fsm that the user is currently waiting
%% for the ready state. State should transition to 'ready'
am_ready(OtherPid) ->
    gen_fsm:send_event(OtherPid, 'ready!').

%% Acknowledge that the fsm is in a ready state.
ack_trans(OtherPid) ->
    gen_fsm:send_event(OtherPid, ack).

%% ask if ready to commit
ask_commit(OtherPid) ->
    gen_fsm:sync_send_event(OtherPid, ask_commit).

%% begin the synchronous commit
do_commit(OtherPid) ->
    gen_fsm:sync_send_event(OtherPid, do_commit).

%% Make the other FSM aware that your client cancelled the trade
notify_cancel(OtherPid) ->
    gen_fsm:send_all_state_event(OtherPid, cancel).

%%% GEN_FSM API
init(Name) -> {ok, idle, #state{name = Name}}.

%% idle state is the state before any trade is done.
%% The other player asks for a negotiation. We basically
%% only wait for our own user to accept the trade,
%% and store the other's Pid for future uses
idle({ask_negotiate, OtherPid}, S = #state{}) ->
    Ref = monitor(process, OtherPid),
    notice(S, "~p asked for a trade negotiation",
	   [OtherPid]),
    {next_state, idle_wait,
     S#state{role = "producer", other = OtherPid,
	     monitor = Ref}};
idle(Event, Data) ->
    unexpected(Event, idle), {next_state, idle, Data}.

%% trade call coming from the user. Forward to the other side,
%% forward it and store the other's Pid
idle({negotiate, OtherPid}, From, S = #state{}) ->
    ask_negotiate(OtherPid, self()),
    notice(S, "asking user ~p for a trade", [OtherPid]),
    Ref = monitor(process, OtherPid),
    {next_state, idle_wait,
     S#state{role = "consumer", other = OtherPid,
	     monitor = Ref, from = From}};
idle(Event, _From, Data) ->
    unexpected(Event, idle), {next_state, idle, Data}.

%% idle_wait allows to expect replies from the other side and
%% start negotiating for items

%% the other side asked for a negotiation while we asked for it too.
%% this means both definitely agree to the idea of doing a trade.
%% Both sides can assume the other feels the same!
idle_wait({ask_negotiate, OtherPid},
	  S = #state{other = OtherPid}) ->
    gen_fsm:reply(S#state.from, ok),
    notice(S, "starting negotiation", []),
    {next_state, negotiate, S};
%% The other side has accepted our offer. Move to negotiate state
idle_wait({accept_negotiate, OtherPid},
	  S = #state{other = OtherPid}) ->
    gen_fsm:reply(S#state.from, ok),
    notice(S, "starting negotiation", []),
    {next_state, negotiate, S};
%% different call from someone else. Not supported! Let it die.
idle_wait(Event, Data) ->
    unexpected(Event, idle_wait),
    {next_state, idle_wait, Data}.

%% Our own client has decided to accept the transaction.
%% Make the other FSM aware of it and move to negotiate state.
idle_wait(accept_negotiate, _From,
	  S = #state{other = OtherPid}) ->
    accept_negotiate(OtherPid, self()),
    notice(S, "accepting negotiation", []),
    {reply, ok, negotiate, S};
idle_wait(Event, _From, Data) ->
    unexpected(Event, idle_wait),
    {next_state, idle_wait, Data}.

%% own side offering an item
negotiate({make_offer, Item}, S = #state{}) ->
    do_offer(S#state.other, Item),
    notice(S, "offering ~p", [Item]),
    {next_state, negotiate, S#state{item = Item}};
%% Own side retracting an item offer
negotiate({retract_offer, Item}, S = #state{}) ->
    undo_offer(S#state.other, Item),
    notice(S, "cancelling offer on ~p", [Item]),
    {next_state, negotiate, S#state{item = ""}};
%% other side offering an item
negotiate({do_offer, Item}, S = #state{}) ->
    notice(S, "other player offering ~p", [Item]),
    {next_state, negotiate, S#state{item = Item}};
%% other side retracting an item offer
negotiate({undo_offer, Item}, S = #state{}) ->
    notice(S, "Other player cancelling offer on ~p",
	   [Item]),
    {next_state, negotiate, S#state{item = ""}};
negotiate({ask_bid, OtherPid}, S = #state{}) ->
    notice(S, "~p asked to start bidding", [OtherPid]),
    {next_state, negotiate_wait, S#state{other = OtherPid}};
negotiate(Event, Data) ->
    unexpected(Event, negotiate),
    {next_state, negotiate, Data}.

negotiate({bid, OtherPid}, From, S = #state{}) ->
    ask_bid(OtherPid, self()),
    notice(S, "asking user ~p to start bidding",
	   [OtherPid]),
    {next_state, negotiate_wait,
     S#state{other = OtherPid, from = From}};
negotiate(Event, _From, S) ->
    unexpected(Event, negotiate),
    {next_state, negotiate, S}.

negotiate_wait({ask_bid, OtherPid},
	       S = #state{other = OtherPid}) ->
    gen_fsm:reply(S#state.from, ok),
    notice(S, "starting bidding", []),
    {next_state, bid, S};
negotiate_wait({accept_bid, OtherPid},
	       S = #state{other = OtherPid}) ->
    gen_fsm:reply(S#state.from, ok),
    notice(S, "starting bidding", []),
    {next_state, bid, S};
negotiate_wait(Event, Data) ->
    unexpected(Event, idle_wait),
    {next_state, negotiate_wait, Data}.

negotiate_wait(accept_bid, _From,
	       S = #state{other = OtherPid}) ->
    accept_bid(OtherPid, self()),
    notice(S, "accepting bidding", []),
    {reply, ok, bid, S};
negotiate_wait(Event, _From, Data) ->
    unexpected(Event, idle_wait),
    {next_state, idle_wait, Data}.

%% Other side sending bid price
bid({do_price, Price}, S = #state{}) ->
    notice(S, "other player bids ~p", [Price]),
    {next_state, bid, S#state{price = Price}};
%% Own side sending bid price
bid({make_price, BidPrice},
    S = #state{role = Role, price = Price}) ->
    if Price == -1 ->
	   do_price(S#state.other, BidPrice),
	   notice(S, "bidding ~p", [BidPrice]),
	   {next_state, bid, S#state{price = BidPrice}};
       true ->
	   case Role of
	     "consumer" ->
		 case BidPrice < Price of
		   true ->
		       do_price(S#state.other, BidPrice),
		       notice(S, "bidding ~p", [BidPrice]),
		       {next_state, bid, S#state{price = BidPrice}};
		   false ->
		       notice(S, "bid lower than current price", []),
		       {next_state, bid, S}
		 end;
	     "producer" ->
		 case BidPrice > Price of
		   true ->
		       do_price(S#state.other, BidPrice),
		       notice(S, "bidding ~p", [BidPrice]),
		       {next_state, bid, S#state{price = BidPrice}};
		   false ->
		       notice(S, "bid higher than current price", []),
		       {next_state, bid, S}
		 end
	   end
    end;
bid(are_you_ready, S = #state{other = OtherPid}) ->
    io:format("Other user ready to trade.~n"),
    notice(S, "Other user ready to trade: ~p for ~p",
	   [S#state.item, S#state.price]),
    not_yet(OtherPid),
    {next_state, bid, S};
bid(Event, Data) ->
    unexpected(Event, bid), {next_state, bid, Data}.

bid(ready, From, S = #state{other = OtherPid}) ->
    are_you_ready(OtherPid),
    notice(S, "asking if ready, waiting", []),
    {next_state, wait, S#state{from = From}};
bid(Event, _From, S) ->
    unexpected(Event, price), {next_state, price, S}.

%% other side offering an item. Don't forget our client is still
%% waiting for a reply, so let's tell them the trade state changed
%% and move back to the negotiate state
wait({do_price, Price}, S = #state{}) ->
    gen_fsm:reply(S#state.from, bid_changed),
    notice(S, "other side offering new price ~p", [Price]),
    {next_state, bid, S#state{price = Price}};
%% The other client falls in ready state and asks us about it.
%% However, the other client could have moved out of wait state already.
%% Because of this, we send that we indeed are 'ready!' and hope for them
%% to do the same.
wait(are_you_ready, S = #state{}) ->
    am_ready(S#state.other),
    notice(S,
	   "asked if ready, and I am. Waiting for "
	   "same reply",
	   []),
    {next_state, wait, S};
%% The other client is not ready to trade yet. We keep waiting
%% and won't reply to our own client yet.
wait(not_yet, S = #state{}) ->
    notice(S, "Other not ready yet", []),
    {next_state, wait, S};
%% The other client was waiting for us! Let's reply to ours and
%% send the ack message for the commit initiation on the other end.
%% We can't go back after this.
wait('ready!', S = #state{}) ->
    am_ready(S#state.other),
    ack_trans(S#state.other),
    gen_fsm:reply(S#state.from, ok),
    notice(S,
	   "other side is ready. Moving to ready "
	   "state",
	   []),
    {next_state, ready, S};
wait(Event, Data) ->
    unexpected(Event, wait), {next_state, wait, Data}.

%% Ready state with the acknowledgement message coming from the
%% other side. We determine if we should begin the synchronous
%% commit or if the other side should.
%% A successful commit (if we initiated it) could be done
%% in the terminate function or any other before.
ready(ack, S = #state{}) ->
    case priority(self(), S#state.other) of
      true ->
	  try notice(S, "asking for commit", []),
	      ready_commit = ask_commit(S#state.other),
	      notice(S, "ordering commit", []),
	      ok = do_commit(S#state.other),
	      notice(S, "committing...", []),
	      commit(S),
	      {stop, normal, S}
	  catch
	    Class:Reason ->
		%% abort! Either ready_commit or do_commit failed
		notice(S, "commit failed", []),
		{stop, {Class, Reason}, S}
	  end;
      false -> {next_state, ready, S}
    end;
ready(Event, Data) ->
    unexpected(Event, ready), {next_state, ready, Data}.

%% We weren't the ones to initiate the commit.
%% Let's reply to the other side to say we're doing our part
%% and terminate.
ready(ask_commit, _From, S) ->
    notice(S, "replying to ask_commit", []),
    {reply, ready_commit, ready, S};
ready(do_commit, _From, S) ->
    notice(S, "committing...", []),
    commit(S),
    {stop, normal, ok, S};
ready(Event, _From, Data) ->
    unexpected(Event, ready), {next_state, ready, Data}.

%% This cancel event has been sent by the other player
%% stop whatever we're doing and shut down!
handle_event(cancel, _StateName, S = #state{}) ->
    notice(S, "received cancel event", []),
    {stop, other_cancelled, S};
handle_event(Event, StateName, Data) ->
    unexpected(Event, StateName),
    {next_state, StateName, Data}.

%% This cancel event comes from the client. We must warn the other
%% player that we have a quitter!
handle_sync_event(cancel, _From, _StateName,
		  S = #state{}) ->
    notify_cancel(S#state.other),
    notice(S, "cancelling trade, sending cancel event", []),
    {stop, cancelled, ok, S};
%% Note: DO NOT reply to unexpected calls. Let the call-maker crash!
handle_sync_event(Event, _From, StateName, Data) ->
    unexpected(Event, StateName),
    {next_state, StateName, Data}.

%% The other player's FSM has gone down. We have
%% to abort the trade.
handle_info({'DOWN', Ref, process, Pid, Reason}, _,
	    S = #state{other = Pid, monitor = Ref}) ->
    notice(S, "Other side dead", []),
    {stop, {other_down, Reason}, S};
handle_info(Info, StateName, Data) ->
    unexpected(Info, StateName),
    {next_state, StateName, Data}.

code_change(_OldVsn, StateName, Data, _Extra) ->
    {ok, StateName, Data}.

%% Transaction completed.
terminate(normal, ready, S = #state{}) ->
    notice(S, "FSM leaving.", []);
terminate(_Reason, _StateName, _StateData) -> ok.

%%% PRIVATE FUNCTIONS

%% adds an item to an item list
add(Item, Items) -> [Item | Items].

%% remove an item from an item list
remove(Item, Items) -> Items -- [Item].

%% Send players a notice. This could be messages to their clients
%% but for our purposes, outputting to the shell is enough.
notice(#state{name = N}, Str, Args) ->
    io:format("~s: " ++ Str ++ "~n", [N | Args]).

%% Unexpected allows to log unexpected messages
unexpected(Msg, State) ->
    io:format("~p received unknown event ~p while in "
	      "state ~p~n",
	      [self(), Msg, State]).

%% This function allows two processes to make a synchronous call to each
%% other by electing one Pid to do it. Both processes call it and it
%% tells them whether they should initiate the call or not.
%% This is done by knowing that Erlang will alwys sort Pids in an
%% absolute manner depending on when and where they were spawned.
priority(OwnPid, OtherPid) when OwnPid > OtherPid ->
    true;
priority(OwnPid, OtherPid) when OwnPid < OtherPid ->
    false.

commit(S = #state{}) ->
    io:format("Transaction completed for ~s. Item  "
	      "is:~n~p,~n price is:~n~p.~n",
	      [S#state.name, S#state.item, S#state.price]).
