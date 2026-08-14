#!/bin/sh
# Simulates a yabai invocation that never returns, regardless of args.
# Sleeps in 1s slices: sh only handles a pending SIGTERM after the current
# foreground child exits, so one long sleep would defer the signal for its
# whole duration and leave a near-immortal orphan `sleep` behind when the
# shell dies. With slices the shell dies within ~1s of SIGTERM and the
# orphaned child expires on its own a second later.
while :; do sleep 1; done
