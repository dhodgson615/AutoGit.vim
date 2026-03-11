# autogit.vim

A Vim plugin that generates Git commit messages using a local Ollama model.

## Requirements

| Requirement | Notes |
|---|---|
| Vim 8+ | Needs `+job` and `+timers` |
| `+python3` | Vim must be compiled with Python 3 support |
| [Ollama](https://ollama.com) | Must be installed and on `$PATH` |
| `ollama` Python package | `pip install ollama` |
| A pulled model | e.g. `ollama pull deepseek-r1:8b` |

## Installation

### vim-plug
```vim
Plug '~/path/to/autogit'   " local
" or
Plug 'yourname/autogit'    " GitHub
```

### Vim packages (built-in)
```sh
mkdir -p ~/.vim/pack/plugins/start
cp -r autogit ~/.vim/pack/plugins/start/
```

## Usage

| Command | Effect |
|---|---|
| `:AutoGit` | Stage + commit the **current file** with an AI message |
| `:AutoGitDir` | Stage + commit all changed files under the **current file's directory** |

## Configuration

Put any of these in your `vimrc` to override the defaults:

```vim
" Ollama model to use (must be pulled first)
let g:autogit_model = 'deepseek-r1:8b'

" Ollama server URL (respects OLLAMA_HOST env var if you set it manually)
let g:autogit_ollama_host = 'http://127.0.0.1:11434'

" Timeout (seconds) for the Ollama health-check probe
let g:autogit_health_timeout = 1.0

" Max seconds to wait for a freshly-started server before giving up
let g:autogit_server_wait = 10
```

## Architecture

```
autogit/
├── plugin/autogit.vim      ← Loaded at startup. Sets config defaults,
│                             registers :AutoGit commands, and fires
│                             autogit#ensure_server() via VimEnter.
│                             Intentionally tiny — no logic here.
│
├── autoload/autogit.vim    ← Lazy-loaded on first :AutoGit call.
│                             Contains all git, Ollama, and Python logic.
│                             s: prefix = script-local (private).
│                             autogit# prefix = public API.
│
└── prompt/
    └── commit_prompt.txt   ← The prompt template. Uses Python .format()
                              placeholders: {filepath}, {file_content}, {diff}.
                              Edit this to tune the model's output style.
```

### Startup flow

```
VimEnter
  └─ autogit#ensure_server()
       ├─ s:is_ollama_reachable()  →  already up? done.
       └─ job_start(['ollama', 'serve'])
            └─ timer polls every 500ms → echomsg when ready
```

### :AutoGit flow

```
:AutoGit
  └─ autogit#run(expand('%:p'))
       ├─ s:is_ollama_reachable()  →  block-wait if needed
       ├─ s:get_git_diff(path)     →  system('git diff ...')
       ├─ s:generate_commit_message()
       │    └─ python3 block: ollama.generate() → extract + normalize
       └─ s:git_add_and_commit()   →  system('git add && git commit')
```

## Customising the prompt

Edit `prompt/commit_prompt.txt`. The three placeholders that will be
substituted are:

- `{filepath}` — the file or directory path passed to `:AutoGit`
- `{file_content}` — the full text of changed file(s)
- `{diff}` — the `git diff` output

Keep the triple-backtick output instruction so the extraction regex works
reliably.