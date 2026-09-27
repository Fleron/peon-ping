#!/usr/bin/env osascript -l JavaScript
// mac-overlay-warcraft.js — macOS-banner-shaped overlay in Warcraft III dialogue style
// Speaker name in gold, spoken line in white (Friz Quadrata if installed, else bundled Marcellus),
// tinted orc red or human navy from the pack manifest. Reads PEON_SOUND_LABEL, PEON_PACK_SPEAKER,
// PEON_PACK_TINT, PEON_NOTIF_TITLE and PEON_SESSION_IDE from the environment.
// Usage: osascript -l JavaScript mac-overlay.js <message> <color> <icon_path> <slot> <dismiss_seconds> [bundle_id] [ide_pid] [session_tty] [subtitle] [position] [notify_type] [all_screens] [screen_index]
//
// Creates a borderless, always-on-top overlay. Shows on all screens by default,
// or on a specific screen when screen_index is provided, or on the focused screen when all_screens is disabled in config.
// Dismisses automatically after <dismiss_seconds> seconds (0 = persistent until clicked).
// If bundle_id is provided, clicking the overlay activates that app (click-to-focus).
// position: top-center (default), top-right, top-left, bottom-right, bottom-left, bottom-center

ObjC.import('Cocoa');
ObjC.import('CoreText');

function run(argv) {
  var message  = argv[0] || 'peon-ping';
  var color    = argv[1] || 'red';
  var iconPath = argv[2] || '';
  var slot     = parseInt(argv[3], 10) || 0;
  var dismiss  = argv[4] !== undefined ? parseFloat(argv[4]) : 4;
  if (isNaN(dismiss)) dismiss = 4;
  var bundleId   = argv[5] || '';
  var idePid     = parseInt(argv[6], 10) || 0;
  var sessionTty = argv[7] || '';
  var subtitle    = argv[8] || '';
  var position    = argv[9] || 'top-center';
  var allScreens  = argv[11] === 'true';
  var screenIdx   = (argv[12] !== undefined && argv[12] !== '') ? parseInt(argv[12], 10) : -1;
  var env = $.NSProcessInfo.processInfo.environment;
  var clickCommandValue = env.objectForKey($('PEON_CLICK_COMMAND'));
  var clickCommand = clickCommandValue && !clickCommandValue.isNil() ? ObjC.unwrap(clickCommandValue) : '';
  var warpFocusUrlValue = env.objectForKey($('PEON_WARP_FOCUS_URL'));
  var warpFocusUrl = warpFocusUrlValue && !warpFocusUrlValue.isNil() ? ObjC.unwrap(warpFocusUrlValue) : '';
  if (warpFocusUrl.indexOf('warp://') !== 0) warpFocusUrl = '';
  var cmuxFocusHelperValue = env.objectForKey($('PEON_CMUX_FOCUS_HELPER'));
  var cmuxFocusCliValue = env.objectForKey($('PEON_CMUX_FOCUS_CLI'));
  var cmuxFocusSocketValue = env.objectForKey($('PEON_CMUX_FOCUS_SOCKET'));
  var cmuxFocusWorkspaceValue = env.objectForKey($('PEON_CMUX_FOCUS_WORKSPACE'));
  var cmuxFocusSurfaceValue = env.objectForKey($('PEON_CMUX_FOCUS_SURFACE'));
  var cmuxFocusHelper = cmuxFocusHelperValue && !cmuxFocusHelperValue.isNil() ? ObjC.unwrap(cmuxFocusHelperValue) : '';
  var cmuxFocusCli = cmuxFocusCliValue && !cmuxFocusCliValue.isNil() ? ObjC.unwrap(cmuxFocusCliValue) : '';
  var cmuxFocusSocket = cmuxFocusSocketValue && !cmuxFocusSocketValue.isNil() ? ObjC.unwrap(cmuxFocusSocketValue) : '';
  var cmuxFocusWorkspace = cmuxFocusWorkspaceValue && !cmuxFocusWorkspaceValue.isNil() ? ObjC.unwrap(cmuxFocusWorkspaceValue) : '';
  var cmuxFocusSurface = cmuxFocusSurfaceValue && !cmuxFocusSurfaceValue.isNil() ? ObjC.unwrap(cmuxFocusSurfaceValue) : '';

  function envStr(name) {
    var v = env.objectForKey($(name));
    return v && !v.isNil() ? ObjC.unwrap(v) : '';
  }
  var voiceLine = envStr('PEON_SOUND_LABEL') || message;
  var speaker   = envStr('PEON_PACK_SPEAKER') || 'Peon';
  var tint      = envStr('PEON_PACK_TINT') || 'orc';
  var project   = envStr('PEON_NOTIF_TITLE');
  var agent     = envStr('PEON_SESSION_IDE') === 'codex' ? 'Codex' : 'Claude';
  var detail    = [project, message, agent].filter(function(p) { return p; }).join(' \u00b7 ');

  var tints = {
    orc:   [84/255, 24/255, 18/255],
    human: [28/255, 52/255, 104/255]
  };
  var rgb = tints[tint] || tints.orc;

  // Friz Quadrata ships with Warcraft III / WoW and is not redistributable, so use it only when installed.
  var scriptDir = $(ObjC.unwrap($.NSProcessInfo.processInfo.arguments.objectAtIndex(3))).stringByDeletingLastPathComponent.js;
  function wcFont(size) {
    var names = ['FrizQuadrataTT', 'Friz Quadrata TT', 'FrizQuadrataStd', 'FrizQuadrataITCbyBT-Roman'];
    for (var n = 0; n < names.length; n++) {
      var f = $.NSFont.fontWithNameSize(names[n], size);
      if (f && !f.isNil()) return f;
    }
    var bundled = $.NSFont.fontWithNameSize('Marcellus-Regular', size);
    if ((!bundled || bundled.isNil()) && !wcFont.registered) {
      wcFont.registered = true;
      var fontPath = scriptDir + '/fonts/Marcellus-Regular.ttf';
      if ($.NSFileManager.defaultManager.fileExistsAtPath(fontPath)) {
        $.CTFontManagerRegisterFontsForURL($.NSURL.fileURLWithPath(fontPath), 1, null);
      }
      bundled = $.NSFont.fontWithNameSize('Marcellus-Regular', size);
    }
    if (bundled && !bundled.isNil()) return bundled;
    return $.NSFont.fontWithNameSize('Georgia', size);
  }
  var winWidth = 360, winHeight = 76;

  $.NSApplication.sharedApplication;
  $.NSApp.setActivationPolicy($.NSApplicationActivationPolicyAccessory);

  var persistent = dismiss <= 0;

  // Generate unique notification ID for all sibling overlays (all-screens mode)
  // All overlays with the same slot will coordinate dismissal
  var dismissNotificationName = 'com.peonping.dismiss.' + slot;

  // Register a click handler if we have a target bundle ID, IDE PID, persistent
  // mode, or a custom click command. The last case covers relay notifications
  // for remote ssh sessions: the hosting terminal isn't known at notify time
  // (it's discovered on click by ssh-focus.sh), so there's no bundle id to key
  // on — the click command alone must make the overlay clickable.
  var clickHandler = null;
  if (bundleId || idePid > 0 || persistent || clickCommand) {
    function activateBundle(targetBundleId) {
      if (!targetBundleId) return false;
      var ws = $.NSWorkspace.sharedWorkspace;
      var apps = ws.runningApplications;
      var count = apps.count;
      for (var i = 0; i < count; i++) {
        var app = apps.objectAtIndex(i);
        var bid = app.bundleIdentifier;
        if (!bid.isNil() && bid.js === targetBundleId) {
          app.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
          return true;
        }
      }
      return false;
    }

    function runClickCommand(command) {
      if (!command) return false;
      try {
        var task = $.NSTask.alloc.init;
        task.setLaunchPath($('/bin/bash'));
        task.setArguments($(['-lc', command]));
        task.launch;
        task.waitUntilExit;
        return task.terminationStatus === 0;
      } catch(e) {
        return false;
      }
    }

    function runCmuxFocusTask() {
      if (!cmuxFocusHelper || !cmuxFocusCli || !cmuxFocusSurface) return false;
      try {
        var args = [cmuxFocusCli];
        if (cmuxFocusSocket) args.push(cmuxFocusSocket);
        if (cmuxFocusWorkspace) args.push(cmuxFocusWorkspace);
        args.push(cmuxFocusSurface);
        var task = $.NSTask.alloc.init;
        task.setLaunchPath($(cmuxFocusHelper));
        task.setArguments($(args));
        task.launch;
        task.waitUntilExit;
        return task.terminationStatus === 0;
      } catch (e) {
        return false;
      }
    }

    ObjC.registerSubclass({
      name: 'PeonClickHandler',
      superclass: 'NSObject',
      methods: {
        'handleClick:': {
          types: ['void', ['id']],
          implementation: function(_sender) {
            if (cmuxFocusHelper && cmuxFocusCli && cmuxFocusSurface) {
              activateBundle(bundleId);
              runCmuxFocusTask();
              $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObject($(dismissNotificationName), $.NSString.string);
              $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(
                0.05, $.NSApp, 'terminate:', null, false
              );
              return;
            }

            // non-cmux: activate the terminal app, raise the tab hosting our
            // session, THEN run any custom focus command (e.g. tmux
            // select-window/select-pane) last — so tmux switches to the
            // agent's pane after the correct terminal tab is already up.
            var activated = false;
            // Warp: activateWithOptions() won't cross Spaces from this
            // accessory-policy process; Warp's deep link does, and also selects
            // the exact tab. Fall back to AppleScript activate (app + Space, no
            // tab) on older Warp. Don't return, so a custom click command (tmux)
            // still runs last, same as every other terminal.
            if (bundleId === 'dev.warp.Warp-Stable') {
              var warpTask = $.NSTask.alloc.init;
              if (warpFocusUrl) {
                warpTask.setLaunchPath($('/usr/bin/open'));
                warpTask.setArguments($([warpFocusUrl]));
              } else {
                warpTask.setLaunchPath($('/usr/bin/osascript'));
                warpTask.setArguments($(['-e', 'tell application "Warp" to activate']));
              }
              warpTask.launch;
              warpTask.waitUntilExit;
              activated = true;
            }
            if (!activated && bundleId) activated = activateBundle(bundleId);
            // Fallback: activate by IDE PID (for embedded terminals)
            if (!activated && idePid > 0) {
              var ideApp = $.NSRunningApplication.runningApplicationWithProcessIdentifier(idePid);
              if (ideApp && !ideApp.isNil()) {
                ideApp.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
              }
            }
            // iTerm2: raise the specific window/tab hosting our session (by tty)
            if (sessionTty && bundleId === 'com.googlecode.iterm2') {
              try {
                var itask = $.NSTask.alloc.init;
                itask.setLaunchPath($('/usr/bin/osascript'));
                itask.setArguments($(['-l', 'JavaScript', '-e',
                  'var iTerm=Application("iTerm2");var ws=iTerm.windows();var f=0;' +
                  'for(var w=0;w<ws.length&&!f;w++){var ts=ws[w].tabs();' +
                  'for(var t=0;t<ts.length&&!f;t++){var ss=ts[t].sessions();' +
                  'for(var s=0;s<ss.length&&!f;s++){try{if(ss[s].tty()==="' + sessionTty + '")' +
                  '{ts[t].select();ss[s].select();var wn=ws[w].name();' +
                  'var se=Application("System Events");var sw=se.processes["iTerm2"].windows();' +
                  'for(var i=0;i<sw.length;i++){try{if(sw[i].name()===wn){sw[i].actions["AXRaise"].perform();break}}catch(e2){}}' +
                  'ws[w].index=1;iTerm.activate();f=1}}catch(e){}}}}'
                ]));
                itask.launch;
                itask.waitUntilExit;
              } catch(e) {}
            }
            // Custom focus command — e.g. `tmux select-window/select-pane` to
            // jump to the agent's OWN pane, which app/tab focus can't reach.
            if (clickCommand) runClickCommand(clickCommand);

            // Signal ALL sibling overlays to dismiss (event-driven, no polling)
            $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObject($(dismissNotificationName), $.NSString.string);
            // Small delay to ensure notification is delivered before we terminate
            $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(
              0.05, $.NSApp, 'terminate:', null, false
            );
          }
        }
      }
    });
    clickHandler = $.PeonClickHandler.alloc.init;
  }

  var screens = $.NSScreen.screens;
  var screenCount = screens.count;
  var windows = [];

  // Determine which screen(s) to display on
  var startIdx = 0, endIdx = screenCount;
  if (screenIdx >= 0 && screenIdx < screenCount) {
    // Specific screen requested (multi-process mode from notify.sh)
    startIdx = screenIdx;
    endIdx = screenIdx + 1;
  } else if (!allScreens) {
    // Single-screen mode: find screen where mouse cursor is
    var mouseLocation = $.NSEvent.mouseLocation;
    var focusedIdx = 0;
    for (var s = 0; s < screenCount; s++) {
      var scr = screens.objectAtIndex(s);
      var sf = scr.frame;
      if (mouseLocation.x >= sf.origin.x && mouseLocation.x <= sf.origin.x + sf.size.width &&
          mouseLocation.y >= sf.origin.y && mouseLocation.y <= sf.origin.y + sf.size.height) {
        focusedIdx = s; break;
      }
    }
    startIdx = focusedIdx;
    endIdx = focusedIdx + 1;
  }

  for (var i = startIdx; i < endIdx; i++) {
    var screen = screens.objectAtIndex(i);
    var visibleFrame = screen.visibleFrame;

    var margin = 10;
    var slotStep = winHeight + margin;
    var ySlotOffset = margin + slot * slotStep;
    var x, y;
    switch (position) {
      case 'top-right':
        x = visibleFrame.origin.x + visibleFrame.size.width - winWidth - margin;
        y = visibleFrame.origin.y + visibleFrame.size.height - winHeight - ySlotOffset;
        break;
      case 'top-left':
        x = visibleFrame.origin.x + margin;
        y = visibleFrame.origin.y + visibleFrame.size.height - winHeight - ySlotOffset;
        break;
      case 'bottom-right':
        x = visibleFrame.origin.x + visibleFrame.size.width - winWidth - margin;
        y = visibleFrame.origin.y + ySlotOffset;
        break;
      case 'bottom-left':
        x = visibleFrame.origin.x + margin;
        y = visibleFrame.origin.y + ySlotOffset;
        break;
      case 'bottom-center':
        x = visibleFrame.origin.x + (visibleFrame.size.width - winWidth) / 2;
        y = visibleFrame.origin.y + ySlotOffset;
        break;
      default: // top-center
        x = visibleFrame.origin.x + (visibleFrame.size.width - winWidth) / 2;
        y = visibleFrame.origin.y + visibleFrame.size.height - winHeight - ySlotOffset;
    }
    var frame = $.NSMakeRect(x, y, winWidth, winHeight);

    var win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
      frame,
      $.NSWindowStyleMaskBorderless,
      $.NSBackingStoreBuffered,
      false
    );

    win.setBackgroundColor($.NSColor.clearColor);
    win.setOpaque(false);
    win.setHasShadow(true);
    win.setLevel($.NSStatusWindowLevel);

    if (!clickHandler) {
      win.setIgnoresMouseEvents(true);
    }

    win.setCollectionBehavior(
      $.NSWindowCollectionBehaviorCanJoinAllSpaces |
      $.NSWindowCollectionBehaviorStationary
    );

    var contentView = win.contentView;
    // NSBox draws the rounded tinted panel from plain NSColors; assigning CGColors to layer
    // properties from JXA crashes osascript.
    var panel = $.NSBox.alloc.initWithFrame($.NSMakeRect(0, 0, winWidth, winHeight));
    panel.setBoxType($.NSBoxCustom);
    panel.setTitlePosition($.NSNoTitle);
    panel.setCornerRadius(18);
    panel.setBorderWidth(0.5);
    panel.setBorderColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(1, 1, 1, 0.2));
    panel.setFillColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(rgb[0], rgb[1], rgb[2], 0.95));
    contentView.addSubview(panel);

    var pad = 12, iconSize = 44;
    var textX = pad;
    if (iconPath !== '' && $.NSFileManager.defaultManager.fileExistsAtPath(iconPath)) {
      var iconImage = $.NSImage.alloc.initWithContentsOfFile(iconPath);
      if (iconImage && !iconImage.isNil()) {
        var iconView = $.NSImageView.alloc.initWithFrame(
          $.NSMakeRect(pad, (winHeight - iconSize) / 2, iconSize, iconSize)
        );
        iconView.setImage(iconImage);
        iconView.setImageScaling($.NSImageScaleProportionallyUpOrDown);
        contentView.addSubview(iconView);
        textX = pad + iconSize + 10;
      }
    }
    var textWidth = winWidth - textX - pad;

    var textShadow = $.NSShadow.alloc.init;
    textShadow.setShadowOffset($.NSMakeSize(0, -1));
    textShadow.setShadowBlurRadius(1);
    textShadow.setShadowColor($.NSColor.colorWithSRGBRedGreenBlueAlpha(0, 0, 0, 0.6));

    function addLabel(text, font, color, y, h) {
      var l = $.NSTextField.alloc.initWithFrame($.NSMakeRect(textX, y, textWidth, h));
      l.setStringValue($(text));
      l.setBezeled(false);
      l.setDrawsBackground(false);
      l.setEditable(false);
      l.setSelectable(false);
      l.setTextColor(color);
      l.setFont(font);
      l.setShadow(textShadow);
      l.setLineBreakMode($.NSLineBreakByTruncatingTail);
      l.cell.setWraps(false);
      contentView.addSubview(l);
    }
    // Rows from the top: speaker (gold), spoken line (white), detail (dim system font).
    addLabel(speaker, wcFont(13), $.NSColor.colorWithSRGBRedGreenBlueAlpha(1.0, 0.8, 0.0, 1.0), winHeight - 26, 18);
    addLabel(voiceLine, wcFont(15.5), $.NSColor.whiteColor, winHeight - 47, 21);
    addLabel(detail, $.NSFont.systemFontOfSize(11.5), $.NSColor.colorWithSRGBRedGreenBlueAlpha(1, 1, 1, 0.8), 9, 16);

    if (clickHandler) {
      // Transparent click-capture button (added last so it sits on top)
      var btn = $.NSButton.alloc.initWithFrame($.NSMakeRect(0, 0, winWidth, winHeight));
      btn.setTitle($(''));
      btn.setBordered(false);
      btn.setTransparent(true);
      btn.setTarget(clickHandler);
      btn.setAction('handleClick:');
      contentView.addSubview(btn);
    }

    win.orderFrontRegardless;
    windows.push(win);
  }

  // Auto-dismiss timer (skip when persistent — dismiss on click only)
  if (dismiss > 0) {
    $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(
      dismiss,
      $.NSApp,
      'terminate:',
      null,
      false
    );
  }

  // Event-driven dismissal: observe distributed notifications from sibling overlays
  // No polling! All overlays with the same slot will dismiss when any one is clicked.
  ObjC.registerSubclass({
    name: 'PeonDismissObserver',
    superclass: 'NSObject',
    methods: {
      'handleDismiss:': {
        types: ['void', ['id']],
        implementation: function(notification) {
          $.NSApp.terminate(null);
        }
      }
    }
  });
  var observer = $.PeonDismissObserver.alloc.init;
  $.NSDistributedNotificationCenter.defaultCenter.addObserverSelectorNameObject(
    observer,
    'handleDismiss:',
    $(dismissNotificationName),
    $.NSString.string
  );

  $.NSApp.run;
}
