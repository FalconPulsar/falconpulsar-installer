// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors
//
// Compiled against the REAL InstallerState.swift (see run.sh) so the wizard's
// navigation rules are asserted, not re-implemented.
//
// The rule under test: may the "Existing Installation Detected" page be
// skipped? It used to be decided by `existing.isEmpty`, which is equally true
// before detection has run and after it has run and found nothing. Detection
// is slow — a `du` walk over a 34GB stack directory plus three docker
// round-trips — so an operator clicking Continue beat it, the page was
// skipped, and a machine with five running containers was offered the
// fresh-install path. Going Back revealed the page, because by then detection
// had finished: the asymmetry a race shows from the outside.

import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    if cond { print("  ✓ \(label)") }
    else { failures += 1; print("  ✗ \(label)") }
}

func stateWithInstall() -> InstallerState {
    let s = InstallerState()
    var found = ExistingInstall()
    found.stackDirExists = true
    found.containers = ["falconpulsar-core"]
    s.existing = found
    return s
}

print("§1 the bug: an unanswered question is not 'nothing installed'")
do {
    let s = InstallerState()
    s.currentPage = .welcome
    s.existingDetectionDone = false     // detection still running
    s.detectingExisting = true
    s.nextPage()
    check("detection in flight → the page is shown, not skipped", s.currentPage == .existing)
}

print("§2 once detection finds an install, the page is shown")
do {
    let s = stateWithInstall()
    s.existingDetectionDone = true
    s.currentPage = .welcome
    s.nextPage()
    check("existing install → page shown", s.currentPage == .existing)
}

print("§3 a genuinely clean machine still skips it")
do {
    let s = InstallerState()
    s.existingDetectionDone = true      // we looked
    s.existing = ExistingInstall()      // and found nothing
    s.currentPage = .welcome
    s.nextPage()
    check("clean machine → page skipped, lands on legal", s.currentPage == .legal)
}

print("§4 back navigation obeys the same rule")
do {
    let clean = InstallerState()
    clean.existingDetectionDone = true
    clean.currentPage = .legal
    clean.prevPage()
    check("skipped forward → skipped back", clean.currentPage == .welcome)

    let dirty = stateWithInstall()
    dirty.existingDetectionDone = true
    dirty.currentPage = .legal
    dirty.prevPage()
    check("shown forward → shown back", dirty.currentPage == .existing)
}

print("§5 the second race the fix opens, and closes")
do {
    // The page can now be on screen while detection finishes, so the late
    // half must never rewrite a deliberate answer.
    let s = stateWithInstall()
    s.installAction = .fresh
    s.installActionUserSet = true
    if s.installActionUserSet != true, s.existing.stackDirExists { s.installAction = .upgrade }
    check("a person chose fresh → detection does not overrule it", s.installAction == .fresh)

    let t = stateWithInstall()
    t.installActionUserSet = false
    if t.installActionUserSet != true, t.existing.stackDirExists { t.installAction = .upgrade }
    check("nobody chose → default still becomes upgrade", t.installAction == .upgrade)
}

print(failures == 0 ? "\nall navigation rules hold" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
