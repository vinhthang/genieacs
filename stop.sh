#! /bin/sh
if tmux has-session -t 'genieacs' 2>/dev/null; then
  tmux kill-session -t genieacs 2>/dev/null
  echo "GenieACS has been stopped."
else
  echo "GenieACS is not running!"
fi

