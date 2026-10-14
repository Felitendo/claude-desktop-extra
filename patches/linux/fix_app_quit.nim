# @patch-target: app.asar.contents/.vite/build/index.js
# @patch-type: nim
#
# Fix app not quitting after cleanup completes.
#
# After the will-quit handler calls preventDefault() and runs cleanup,
# calling app.quit() again becomes a no-op on Linux. The will-quit event
# never fires again, leaving the app stuck.
#
# Solution: Use app.exit(0) instead of app.quit() after cleanup is complete.
# Since all cleanup handlers have already run (mcp-shutdown, quick-entry-cleanup,
# prototype-cleanup), we can safely force exit. Using setImmediate ensures
# the exit happens in the next event loop tick.
#
# Upstream (v2.7032.0) arms its own "Quit watchdog" on the same success path:
# an unref'd 15 s timer (5 s unpackaged) that forces app.exit(0) if the event
# loop is still alive. So without this patch a stuck quit still ends, just up
# to ~15 s later (and reports desktop_quit_watchdog_fired). Re-check on each
# bump whether the second app.quit() still stalls on Linux at all; if it no
# longer does, this patch only shortens an already-bounded wait.
#
# Sub-patch B - quit backstop. With Electron 44.7.0 (v2.37337.1) a SIGTERM to
# the whole process group (logout, `systemctl stop` on the app's scope, pkill,
# Ctrl+C) also kills the zygotes; every GPU relaunch then fails at once and,
# with upstream's disable-gpu-process-crash-limit switch, is retried forever.
# 44.7.0 fires app 'child-process-gone' per failure, and upstream's handler
# plus Sentry's listeners keep the main thread busy, so Electron never leaves
# its loop after 'quit': app.exit(0), process.exit(0) and upstream's 15 s
# watchdog all do nothing, and the process spins until SIGKILL (90 s under
# systemd). A healthy quit is gone milliseconds after 'quit', so a timer that
# still fires 3 s later only fires in that stuck state; process.reallyExit(0)
# (Node's raw exit, past Electron's routing) is the one call that still ends it.

import std/[os, strutils]
import regex

const EXPECTED_PATCHES = 2 # A: app.quit -> app.exit, B: quit backstop

proc applyQuitBackstop(input: string, applied: var int): string =
  let pattern = re2"""([\w$]+)\.app\.on\("will-quit",[\w$]+\("willQuit"\)\),"""
  let marker =
    re2"""\.app\.on\("quit",\(\)=>\{setTimeout\(\(\)=>\{\(globalThis\.__cdbDiag\|\|console\.log\)\("\[quit-backstop\][^"]*"\);process\.reallyExit\(0\)\},3e3\)\}\),"""
  let count = input.findAll(pattern).len
  let done = input.findAll(marker).len
  if done == 1:
    echo "  [OK] quit backstop: already applied (idempotent)"
    inc applied
    return input
  if count != 1 or done != 0:
    echo "  [FAIL] quit backstop: " & $count & " will-quit anchors and " & $done &
      " backstops, expected exactly 1 anchor"
    return input
  result = input.replace(
    pattern,
    proc(m: RegexMatch2, s: string): string =
      let electronVar = s[m.group(0)]
      s[m.boundaries] & electronVar &
        ".app.on(\"quit\",()=>{setTimeout(()=>{(globalThis.__cdbDiag||console.log)(" &
        "\"[quit-backstop] still alive 3s after quit, process.reallyExit(0)\");" &
        "process.reallyExit(0)},3e3)}),",
  )
  echo "  [OK] quit backstop: 1 match"
  inc applied

proc applyQuitToExit(input: string, applied: var int): string =
  # Original pattern: clearTimeout(n)}XX&&YY.app.quit()}
  # Variables change between versions (e.g., S_&&he -> TS&&ce)
  # Note: [\w$]+ is used because minified JS names can contain $ (e.g., f$, u$)
  # The XX&&YY.app.quit() doesn't work after preventDefault() on Linux
  # Replace with setImmediate + app.exit(0) for reliable exit
  let pattern = re2"(clearTimeout\([\w$]+\)\})([\w$]+)&&([\w$]+)(\.app\.quit\(\))"
  # Our end state (positive idempotency marker, AGENTS.md Rule 6).
  let patternDone =
    re2"clearTimeout\([\w$]+\)\}if\([\w$]+\)\{setImmediate\(\(\)=>[\w$]+\.app\.exit\(0\)\)\}"
  let count = input.findAll(pattern).len
  let done = input.findAll(patternDone).len
  if count == 0 and done == 1:
    echo "  [OK] app.quit -> app.exit: already applied (idempotent)"
    inc applied
    return input
  if count != 1 or done != 0:
    if ".app.quit()" in input:
      echo "  [INFO] Found '.app.quit()' in file but pattern didn't match exactly once"
    echo "  [FAIL] app.quit pattern: " & $count & " upstream and " & $done &
      " patched sites, expected exactly 1 upstream site"
    return input
  result = input.replace(
    pattern,
    proc(m: RegexMatch2, s: string): string =
      let grp0 = s[m.group(0)] # clearTimeout(n)}
      let flagVar = s[m.group(1)] # XX
      let electronVar = s[m.group(2)] # YY
      # group(3) is .app.quit() -- we discard it
      grp0 & "if(" & flagVar & "){setImmediate(()=>" & electronVar & ".app.exit(0))}",
  )
  echo "  [OK] app.quit -> app.exit: 1 match"
  inc applied

proc apply*(input: string): string =
  var applied = 0
  result = applyQuitBackstop(applyQuitToExit(input, applied), applied)
  if applied < EXPECTED_PATCHES:
    echo "  [FAIL] Only " & $applied & "/" & $EXPECTED_PATCHES & " patches applied"
    quit(1)

when isMainModule:
  if paramCount() != 1:
    echo "Usage: fix_app_quit <file>"
    quit(1)
  let filePath = paramStr(1)
  echo "=== Patch: fix_app_quit ==="
  echo "  Target: " & filePath
  let input = readFile(filePath)
  let output = apply(input)
  if output != input:
    writeFile(filePath, output)
  echo "  [PASS] App quit patched successfully (2/2)"
