# Bash completions for claude-code-sandbox
# Before -- complete directories; after -- args are passed to claude.
_claude_code_sandbox() {
    local cur i past_separator=0
    cur="${COMP_WORDS[COMP_CWORD]}"
    for (( i=1; i < COMP_CWORD; i++ )); do
        if [[ "${COMP_WORDS[i]}" == "--" ]]; then
            past_separator=1
            break
        fi
    done
    if (( ! past_separator )); then
        COMPREPLY=( $(compgen -d -- "$cur") )
    fi
}
complete -o filenames -F _claude_code_sandbox claude-code-sandbox
