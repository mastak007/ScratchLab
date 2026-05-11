#!/bin/sh

set -eu

printf 'pwd\n'
pwd

printf '\ngit branch --show-current\n'
git branch --show-current

printf '\ngit rev-parse --short HEAD\n'
git rev-parse --short HEAD

printf '\ngit status --short\n'
git status --short

printf '\nlatest 8 commits\n'
git log --oneline -8

for path in \
  AGENTS.md \
  CLAUDE.md \
  SOUL.md \
  PROFILE.md \
  AI_HANDOFF.md \
  AI_HANDOFF/next_prompt.md
do
  if [ -e "$path" ]; then
    printf '\n%s: present\n' "$path"
  else
    printf '\n%s: missing\n' "$path"
  fi
done
