#!/bin/zsh
N=$1; shift; NAME=$1; shift
c=0; t=0; det=""
for i in $(seq 1 $N); do
  line=$(./tpcorrupt --name=$NAME "$@" 2>&1 | grep "^\[$NAME\]")
  v=$(echo "$line" | awk '{print $2}')
  cr=$(echo "$line" | grep -o 'corr=[-0-9.]*' | cut -d= -f2)
  det="$det $v($cr)"
  t=$((t+1)); [[ "$v" == "CORRUPT" || "$v" == "SUSPECT" ]] && c=$((c+1))
done
printf "%-26s %d/%d  %s\n" "$NAME" $c $t "$det"
