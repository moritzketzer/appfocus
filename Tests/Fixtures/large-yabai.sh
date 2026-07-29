#!/bin/sh
# Emits a valid `yabai -m query --windows` style JSON array large enough
# (>16KB) to overflow the OS pipe buffer. A reader that drains the pipe only
# after the process exits deadlocks here: this script blocks on write and never
# exits, exactly reproducing the "running but no windows" production bug.
count=60
printf '['
i=1
while [ "$i" -le "$count" ]; do
	[ "$i" -gt 1 ] && printf ','
	printf '{"id":%d,"app":"TestApp","space":1,"title":"window %d padding aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","role":"AXWindow","subrole":"AXStandardWindow","has-ax-reference":true,"is-minimized":false}' "$i" "$i"
	i=$((i + 1))
done
printf ']'
