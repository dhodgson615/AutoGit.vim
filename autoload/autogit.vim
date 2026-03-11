" autogit/autoload/autogit.vim
" Core logic — lazy-loaded on first call to any autogit#* function.
" Requires: Vim 8+ (job_start), +python3, ollama Python package.

" ── Module state ─────────────────────────────────────────────────────────────

" Handle to the script-managed Ollama server job (v:null if not started by us).
let s:server_job = v:null

" Resolved path to the plugin's root directory (two levels up from this file).
let s:plugin_root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')

" ── Public API ───────────────────────────────────────────────────────────────

" autogit#ensure_server()
" Called at VimEnter. Starts Ollama asynchronously if it is not already up.
function! autogit#ensure_server() abort
  if !s:has_requirements()
    return
  endif

  if s:is_ollama_reachable()
    return
  endif

  echomsg '[AutoGit] Ollama not detected — starting server...'
  let s:server_job = job_start(['ollama', 'serve'], {
        \ 'out_io':  'null',
        \ 'err_io':  'null',
        \ 'exit_cb': function('s:on_server_exit'),
        \ })

  " Lightweight background poll; we do NOT block Vim startup.
  call timer_start(500, function('s:poll_server'), {'repeat': g:autogit_server_wait * 2})
endfunction

" autogit#run(path)
" Entry point for :AutoGit and :AutoGitDir. Orchestrates the full workflow.
function! autogit#run(path) abort
  if !s:has_requirements()
    return
  endif

  " Ensure server is up (blocks briefly only if it was not already running).
  if !s:is_ollama_reachable()
    echomsg '[AutoGit] Waiting for Ollama server...'
    if !s:wait_for_server(g:autogit_server_wait)
      echohl ErrorMsg
      echomsg '[AutoGit] Error: Ollama server not reachable. Run `ollama serve` and retry.'
      echohl None
      return
    endif
  endif

  let l:is_dir = isdirectory(a:path)

  " ── Gather diff & file content ───────────────────────────────────────────
  if l:is_dir
    let [l:content, l:diff] = s:build_directory_context(a:path)
  else
    let l:content = s:read_file(a:path)
    let l:diff    = s:get_git_diff(a:path)
  endif

  if empty(trim(l:diff))
    echohl WarningMsg
    echomsg printf("[AutoGit] Warning: no git changes found under '%s'.", a:path)
    echohl None
    return
  endif

  " ── Generate commit message ──────────────────────────────────────────────
  echomsg '[AutoGit] Generating commit message...'
  let l:message = s:generate_commit_message(a:path, l:content, l:diff)

  if empty(l:message)
    echohl ErrorMsg
    echomsg '[AutoGit] Error: failed to generate a commit message.'
    echohl None
    return
  endif

  " ── Stage + commit ───────────────────────────────────────────────────────
  echomsg printf("[AutoGit] Committing: %s", l:message)
  call s:git_add_and_commit(a:path, l:message)
endfunction

" ── Git helpers ──────────────────────────────────────────────────────────────

" Return the combined unstaged + staged diff for a single file.
function! s:get_git_diff(filepath) abort
  let l:unstaged = system(printf('git diff -- %s', shellescape(a:filepath)))
  let l:staged   = system(printf('git diff --cached -- %s', shellescape(a:filepath)))
  return join(filter([trim(l:unstaged), trim(l:staged)], '!empty(v:val)'), "\n\n")
endfunction

" Return a sorted list of changed files (staged + unstaged) under path.
function! s:get_changed_files(path) abort
  let l:unstaged = systemlist(printf('git diff --name-only -- %s', shellescape(a:path)))
  let l:staged   = systemlist(printf('git diff --cached --name-only -- %s', shellescape(a:path)))
  " Deduplicate and sort.
  let l:all = {}
  for l:f in (l:unstaged + l:staged)
    let l:f = trim(l:f)
    if !empty(l:f)
      let l:all[l:f] = 1
    endif
  endfor
  return sort(keys(l:all))
endfunction

" Build aggregated file-content + diff strings for a directory scope.
" Returns a two-element list: [content_string, diff_string].
function! s:build_directory_context(directory) abort
  let l:files = s:get_changed_files(a:directory)
  if empty(l:files)
    return ['', '']
  endif

  let l:content_parts = []
  let l:diff_parts    = []

  for l:f in l:files
    let l:text = filereadable(l:f) ? join(readfile(l:f), "\n") : '[File no longer exists in working tree]'
    call add(l:content_parts, printf("File: %s\n```\n%s\n```", l:f, l:text))

    let l:file_diff = s:get_git_diff(l:f)
    if !empty(trim(l:file_diff))
      call add(l:diff_parts, printf("File: %s\n%s", l:f, l:file_diff))
    endif
  endfor

  return [join(l:content_parts, "\n\n"), join(l:diff_parts, "\n\n")]
endfunction

" Stage filepath and commit with message.
function! s:git_add_and_commit(filepath, message) abort
  call system(printf('git add %s', shellescape(a:filepath)))
  if v:shell_error
    echohl ErrorMsg
    echomsg printf("[AutoGit] Error: `git add` failed for '%s'.", a:filepath)
    echohl None
    return
  endif

  " Write the message to a temp file and use git commit -F to avoid any
  " shell quoting issues with special characters in the message.
  let l:tmpfile = tempname()
  call writefile(split(a:message, "\n", 1), l:tmpfile, 'b')
  call system(printf('git commit -F %s', shellescape(l:tmpfile)))
  call delete(l:tmpfile)
  if v:shell_error
    echohl ErrorMsg
    echomsg '[AutoGit] Error: `git commit` failed.'
    echohl None
  else
    echomsg printf("[AutoGit] Committed: %s", a:message)
  endif
endfunction

" ── Ollama / generation helpers ───────────────────────────────────────────────

" Call Ollama via the Python ollama library.
" Returns the cleaned commit message string, or '' on failure.
function! s:generate_commit_message(filepath, file_content, diff) abort
  let l:result = ''

python3 << PYEOF
import vim, sys, re

def _extract_from_backticks(text):
    """Pull content from triple- or single-backtick blocks."""
    m = re.search(r'```(?:[a-zA-Z0-9_-]+)?\s*([\s\S]*?)\s*```', text)
    if m:
        return _normalize(m.group(1))
    m = re.search(r'`([^`\r\n]+)`', text)
    if m:
        return _normalize(' '.join(m.group(1).split()))
    return ''

def _normalize(msg):
    """Strip markdown noise; ensure the message starts with a letter/digit."""
    msg = msg.strip()
    msg = re.sub(r'^```(?:[a-zA-Z0-9_-]+)?\s*', '', msg)
    msg = re.sub(r'\s*```$', '', msg)
    msg = msg.replace('`', '')
    msg = ' '.join(msg.split())
    # Preserve conventional-commit prefixes like feat:, fix(scope):
    if re.match(r'^[A-Za-z]+(?:\([^)]+\))?!?:', msg):
        return msg
    return re.sub(r'^[^A-Za-z0-9]+', '', msg).strip()

try:
    from ollama import generate as ollama_generate

    plugin_root  = vim.eval('s:plugin_root')
    filepath     = vim.eval('a:filepath')
    file_content = vim.eval('a:file_content')
    diff         = vim.eval('a:diff')
    model        = vim.eval('g:autogit_model')

    import pathlib
    prompt_path = pathlib.Path(plugin_root) / 'prompt' / 'commit_prompt.txt'
    template    = prompt_path.read_text(encoding='utf-8')
    prompt      = template.format(
        filepath=filepath,
        file_content=file_content,
        diff=diff,
    )

    response = ollama_generate(model=model, prompt=prompt, stream=False)
    raw      = response['response'].strip()

    message = _extract_from_backticks(raw) or _normalize(raw)

    # Use vim.vars to assign safely — avoids any escaping issues.
    vim.vars['_autogit_result'] = message
    vim.command("let l:result = get(g:, '_autogit_result', '')")
    vim.command("unlet! g:_autogit_result")

except Exception as exc:
    vim.vars['_autogit_errmsg'] = '[AutoGit] Python error: ' + str(exc)
    vim.command("echohl ErrorMsg")
    vim.command("echomsg get(g:, '_autogit_errmsg', '')")
    vim.command("echohl None")
    vim.command("unlet! g:_autogit_errmsg")
PYEOF

  return l:result
endfunction

" ── Ollama server management ─────────────────────────────────────────────────

" Return 1 if the Ollama HTTP API responds successfully.
function! s:is_ollama_reachable() abort
  let l:ok = 0
python3 << PYEOF
import vim
try:
    from urllib.request import urlopen
    host    = vim.eval('g:autogit_ollama_host').rstrip('/')
    timeout = float(vim.eval('g:autogit_health_timeout'))
    with urlopen(f'{host}/api/tags', timeout=timeout) as r:
        vim.command('let l:ok = ' + ('1' if 200 <= r.status < 300 else '0'))
except Exception:
    vim.command('let l:ok = 0')
PYEOF
  return l:ok
endfunction

" Poll callback invoked by timer_start; cancels itself once server is up.
function! s:poll_server(timer_id) abort
  if s:is_ollama_reachable()
    echomsg '[AutoGit] Ollama server is ready.'
    call timer_stop(a:timer_id)
  endif
endfunction

" Synchronously wait up to max_seconds for the server to become reachable.
" Returns 1 on success, 0 on timeout.
function! s:wait_for_server(max_seconds) abort
  let l:deadline = localtime() + a:max_seconds
  while localtime() < l:deadline
    if s:is_ollama_reachable()
      return 1
    endif
    sleep 250m
  endwhile
  return 0
endfunction

" exit_cb for the Ollama server job.
function! s:on_server_exit(job, exit_code) abort
  if a:exit_code != 0
    echohl WarningMsg
    echomsg printf('[AutoGit] Ollama server exited with code %d.', a:exit_code)
    echohl None
  endif
  let s:server_job = v:null
endfunction

" ── Utility ──────────────────────────────────────────────────────────────────

" Read a file from disk; return its content as a single string.
function! s:read_file(filepath) abort
  if !filereadable(a:filepath)
    return ''
  endif
  return join(readfile(a:filepath), "\n")
endfunction

" Guard: verify Vim has the features this plugin needs.
function! s:has_requirements() abort
  if !has('python3')
    echohl ErrorMsg
    echomsg '[AutoGit] Error: Vim must be compiled with +python3 support.'
    echohl None
    return 0
  endif
  if !has('job')
    echohl ErrorMsg
    echomsg '[AutoGit] Error: Vim must support jobs (Vim 8+ required).'
    echohl None
    return 0
  endif
  return 1
endfunction
