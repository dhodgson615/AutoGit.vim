" autogit/plugin/autogit.vim
" Bootstrap: loaded once at Vim startup.
" Keep this file minimal — heavy logic lives in autoload/autogit.vim.

if exists('g:loaded_autogit')
  finish
endif
let g:loaded_autogit = 1

" ── User-configurable globals ────────────────────────────────────────────────
" Override any of these in your vimrc before the plugin loads.

" Ollama model to use for commit-message generation.
let g:autogit_model = get(g:, 'autogit_model', 'deepseek-r1:8b')

" Base URL of the Ollama server.
let g:autogit_ollama_host = get(g:, 'autogit_ollama_host', 'http://127.0.0.1:11434')

" Health-check timeout when probing Ollama (seconds, float).
let g:autogit_health_timeout = get(g:, 'autogit_health_timeout', 1.0)

" How long to wait for a freshly-started Ollama server (seconds).
let g:autogit_server_wait = get(g:, 'autogit_server_wait', 10)

" ── Commands ─────────────────────────────────────────────────────────────────

" Stage and commit the current file using an AI-generated message.
command! -nargs=0 AutoGit call autogit#run(expand('%:p'))

" Stage and commit everything under the current file's directory.
command! -nargs=0 AutoGitDir call autogit#run(expand('%:p:h'))

" ── Server startup on Vim launch ─────────────────────────────────────────────
" We start the Ollama process early so it is warm by the time :AutoGit is used.
" The autoload function is called here; Vim defers its load until first use.
augroup autogit_startup
  autocmd!
  autocmd VimEnter * call autogit#ensure_server()
augroup END
