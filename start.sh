#! /bin/sh
if tmux has-session -t 'genieacs'; then
  echo "GenieACS is already running."
  echo "To stop it use: ./genieacs-stop.sh"
  echo "To attach to it use: tmux attach -t genieacs"
else
  tmux new-session -s 'genieacs' -d
  tmux send-keys 'nohup ./bin/genieacs-cwmp >> logs/cwmp.log &' 'C-m'
  tmux split-window
  tmux send-keys 'nohup ./bin/genieacs-nbi >> logs/nbi.log &' 'C-m'
  tmux split-window
  tmux send-keys 'nohup ./bin/genieacs-fs >> logs/fs.log &' 'C-m'

  echo "GenieACS has been started in tmux session 'geneiacs'"
  echo "To attach to session, use: tmux attach -t genieacs"
  echo "To switch between panes use Ctrl+B-ArrowKey"
  echo "To deattach, press Ctrl+B-D"
  echo "To stop GenieACS, use: ./genieacs-stop.sh"
fi

