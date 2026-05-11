# Fish completions for claude-code-sandbox
# Before -- complete directories; after -- args are passed to claude.
function __claude_code_sandbox_before_separator
    not contains -- -- (commandline -opc)
end
complete -c claude-code-sandbox -n __claude_code_sandbox_before_separator -f -a '(__fish_complete_directories)'
