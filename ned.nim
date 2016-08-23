# NEd (NimEd) -- a GTK3/GtkSourceView Nim editor with nimsuggest support 
# S. Salewski, 2016-AUG-23
# v 0.3
#
# Note: for resetting gsettings database:
# gsettings --schemadir "." reset-recursively "org.gtk.ned"
#
{.deadCodeElim: on.}
{.link: "resources.o".}

import gobject, gtk3, gdk3, gio, glib, gtksource, gdk_pixbuf, pango
import osproc, streams, os, net, strutils, sequtils, parseutils, locks, times #, strscans, logging

# Since the 3.20 version, if @line_number is greater than the number of lines
# in the @buffer, the end iterator is returned. And if @byte_index is off the
# end of the line, the iterator at the end of the line is returned.
proc getIterAtLineIndex320(buffer: gtk3.TextBuffer; iter: var gtk3.TextIterObj; lineNumber: cint; byteIndex: cint) =
  var endLineIter: TextIterObj
  if lineNumber >= buffer.lineCount:
    buffer.getEndIter(iter)
    return
  buffer.getIterAtLine(iter, lineNumber)
  endLineIter = iter
  if not endLineIter.endsLine:
    discard endLineIter.forwardToLineEnd
  if byteIndex <= endLineIter.lineIndex:
    iter.lineIndex = byteIndex
  else:
    iter = endLineIter

const
  ProgramName = "NEd"
  MaxErrorTags = 8
  NullStr = cast[cstring](nil)
  ErrorTagName = "error"
  HighlightTagName = "high"
  NSPort = Port(6000)
  StyleSchemeSettingsID = cstring("styleschemesettingsid") # must be lower case
  FontSettingsID = cstring("fontsettingsid") # must be lower case
  UseCat = "UseCat"

type
  LogLevel {.pure.} = enum
    debug, log, warn, error

var nsProcess: Process # nimsuggest

var statusLock: Lock # threads display messages on statusbar
initLock(statusLock)

type # for channel communication
  StatusMsg = object
    filepath: string
    dirtypath: string
    line: int
    column: int

type
  NimEdAppWindow* = ptr NimEdAppWindowObj
  NimEdAppWindowObj* = object of gtk3.ApplicationWindowObj
    grid: gtk3.Grid
    settings: gio.GSettings
    gears: MenuButton
    searchentry: SearchEntry
    entry: Entry
    searchcountlabel: Label
    statuslabel: Label
    headerbar: Headerbar
    statusbar: Statusbar
    savebutton: Button
    searchMatchBg: string
    searchMatchFg: string
    openbutton: Button
    buffers: GList
    views: GList
    target: Notebook # where to open "Goto Definition" view
    statusID1: cuint
    statusID2: cuint
    messageId: cuint
    timeoutEventSourceID: cuint
    logLevel: LogLevel

  NimEdAppWindowClass = ptr NimEdAppWindowClassObj
  NimEdAppWindowClassObj = object of gtk3.ApplicationWindowClassObj

gDefineType(NimEdAppWindow, applicationWindowGetType())

template typeNimEdAppWindow*(): expr = nimEdAppWindowGetType()

proc nimEdAppWindow*(obj: GPointer): NimEdAppWindow =
  gTypeCheckInstanceCast(obj, typeNimEdAppWindow, NimEdAppWindowObj)

proc isNimEdAppWindow*(obj: GPointer): GBoolean =
  gTypeCheckInstanceType(obj, typeNimEdAppWindow)

var thread: Thread[NimEdAppWindow]
var channel: system.Channel[StatusMsg]
open(channel)

type
  NimViewError = tuple
    gs: GString
    line, col, id: int

type
  NimView = ptr NimViewObj
  NimViewObj = object of gtksource.ViewObj
    errors: GList
    idleScroll: cuint
    searchSettings: SearchSettings
    searchContext: SearchContext
    label: Label

  NimViewClass = ptr NimViewClassObj
  NimViewClassObj = object of gtksource.ViewClassObj

gDefineType(NimView, viewGetType())

template typeNimView*(): expr = nimViewGetType()

proc nimView(obj: GPointer): NimView =
  gTypeCheckInstanceCast(obj, nimViewGetType(), NimViewObj)

proc isNimView*(obj: GPointer): GBoolean =
  gTypeCheckInstanceType(obj, typeNimView)

proc nimViewDispose(obj: GObject) {.cdecl.} =
  let view = nimView(obj)
  if view.idleScroll != 0:
    discard sourceRemove(view.idleScroll)
    view.idleScroll = 0
  gObjectClass(nimViewParentClass).dispose(obj)

proc freeNVE(data: Gpointer) {.cdecl.} =
  let e = cast[ptr NimViewError](data)
  discard glib.free(e.gs, true)
  glib.free(data)

proc freeErrors(v: var NimView) {.cdecl.} =
  glib.freeFull(v.errors, freeNVE)
  v.errors = nil

proc nimViewFinalize(gobject: GObject) {.cdecl.} =
  var self = nimView(gobject)
  self.freeErrors
  gObjectClass(nimViewParentClass).finalize(gobject)

proc nimViewClassInit(klass: NimViewClass) =
  klass.dispose = nimViewDispose
  klass.finalize = nimViewFinalize

proc nimViewInit(self: NimView) =
  discard

proc newNimView*(buffer: gtksource.Buffer): NimView =
  nimView(newObject(nimViewGetType(), "buffer", buffer, nil))

# return errorID > 0 when new error position, or 0 for old position
proc addError(v: NimView, s: cstring; line, col: int): int =
  var
    el: ptr NimViewError
    p: GList = v.errors
  while p != nil:
    el = cast[ptr NimViewError](p.data)
    if el.line == line and el.col == col:
      el.gs.appendPrintf("\n%s", s)
      return 0
    p = p.next
  let i = system.int(v.errors.length) + 1
  if i > MaxErrorTags: return 0
  el = cast[ptr NimViewError](glib.malloc(sizeof(NimViewError)))
  el.gs = glib.newGString(s)
  el.line = line
  el.col = col
  el.id = i
  v.errors = glib.prepend(v.errors, el)
  return i

type
  NimViewBuffer = ptr NimViewBufferObj
  NimViewBufferObj = object of gtksource.BufferObj
    path: cstring
    defView: bool # buffer is from "Goto Definition", we may replace it
    handlerID: culong # from notify::cursor-position callback

  NimViewBufferClass = ptr NimViewBufferClassObj
  NimViewBufferClassObj = object of gtksource.BufferClassObj

gDefineType(NimViewBuffer, gtksource.bufferGetType())

template typeNimViewBuffer*(): expr = nimViewBufferGetType()

proc nimViewBuffer(obj: GPointer): NimViewBuffer =
  gTypeCheckInstanceCast(obj, nimViewBufferGetType(), NimViewBufferObj)

proc isNimViewBuffer*(obj: GPointer): GBoolean =
  gTypeCheckInstanceType(obj, typeNimViewBuffer)

proc nimViewBufferDispose(obj: GObject) {.cdecl.} =
  gObjectClass(nimViewBufferParentClass).dispose(obj)

proc nimViewBufferFinalize(gobject: GObject) {.cdecl.} =
  free(nimViewBuffer(gobject).path)
  gObjectClass(nimViewBufferParentClass).finalize(gobject)

proc nimViewBufferClassInit(klass: NimViewBufferClass) =
  klass.dispose = nimViewBufferDispose
  klass.finalize = nimViewBufferFinalize

proc setPath(buffer: NimViewBuffer; str: cstring) =
  free(buffer.path)
  buffer.path = dup(str)

proc nimViewBufferInit(self: NimViewBuffer) =
  discard

proc newNimViewBuffer(language: gtksource.Language): NimViewBuffer =
  nimViewBuffer(newObject(nimViewBufferGetType(), "tag-table", nil, "language", language, nil))

proc buffer(view: NimView): NimViewBuffer =
  nimViewBuffer(view.getBuffer)

# this hack is from gedit 3.20
proc scrollToCursor(v: GPointer): GBoolean {.cdecl.} =
  let v = nimView(v)
  let buffer = v.buffer
  v.scrollToMark(buffer.insert, withinMargin = 0.25, useAlign = false, xalign = 0, yalign = 0)
  v.idleScroll = 0
  return G_SOURCE_REMOVE

type
  Provider = ptr ProviderObj
  ProviderObj = object of CompletionProviderObj
    proposals: GList
    priority: cint
    win: NimEdAppWindow
    name: cstring
    icon: GdkPixbuf

  ProviderPrivate = ptr ProviderPrivateObj
  ProviderPrivateObj = object

  ProviderClass = ptr ProviderClassObj
  ProviderClassObj = object of GObjectClassObj

proc providerIfaceInit(iface: CompletionProviderIface) {.cdecl.}

# typeIface: The GType of the interface to add
# ifaceInit: The interface init function
proc gImplementInterfaceStr*(typeIface, ifaceInit: string): string =
  """
var gImplementInterfaceInfo = GInterfaceInfoObj(interfaceInit: cast[GInterfaceInitFunc]($2),
                                                     interfaceFinalize: nil,
                                                     interfaceData: nil)
addInterfaceStatic(gDefineTypeId, $1, addr(gImplementInterfaceInfo))

""" % [typeIface, ifaceInit]

gDefineTypeExtended(Provider, objectGetType(), 0,
  gImplementInterfaceStr("completionProviderGetType()", "providerIfaceInit"))

template typeProvider*(): expr = providerGetType()

proc provider(obj: GObject): Provider =
  gTypeCheckInstanceCast(obj, providerGetType(), ProviderObj)

proc isProvider*(obj: expr): bool =
  gTypeCheckInstanceType(obj, typeProvider)

proc providerGetName(provider: CompletionProvider): cstring {.cdecl.} =
  dup(provider(provider).name) # we really need the provider() cast here and below...

proc providerGetPriority(provider: CompletionProvider): cint {.cdecl.} =
  provider(provider).priority

proc providerGetIcon(provider: CompletionProvider): GdkPixbuf =
  let tp  = provider(provider)
  var error: GError
  if tp.icon.isNil:
    let theme = gtk3.iconThemeGetDefault()
    tp.icon = gtk3.loadIcon(theme, "dialog-information", 16, cast[IconLookupFlags](0), error)
  return tp.icon

## returns dirtypath or nil for failure
proc saveDirty(filepath: string; text: cstring): string =
  var gerror: GError
  var gfile: GFile
  var stream: GFileIOStream
  let filename = filepath.splitFile[1] & "XXXXXX.nim"
  gfile = newFile(filename, stream, gerror)
  if gfile.isNil:
    #error(gerror.message)
    #error("Can't create nimsuggest dirty file")
    return
  let h = gfile.path
  result = $h
  free(h)
  let res = gfile.replaceContents(text, len(text), etag = nil, makeBackup = false, GFileCreateFlags.PRIVATE, newEtag = nil, cancellable = nil, gerror)
  objectUnref(gfile)
  # should we do this here? free(text)
  if not res:
    #error(gerror.message)
    result = nil

type
  NimEdApp* = ptr NimEdAppObj
  NimEdAppObj = object of ApplicationObj
    lastActiveView: NimView

  NimEdAppClass = ptr NimEdAppClassObj
  NimEdAppClassObj = object of ApplicationClassObj

gDefineType(NimEdApp, gtk3.applicationGetType())

proc nimEdAppInit(self: NimEdApp) = discard

template typeNimEdApp*(): expr = nimEdAppGetType()

proc nimEdApp(obj: GPointer): NimEdApp =
  gTypeCheckInstanceCast(obj, nimEdAppGetType(), NimEdAppObj)

proc isNimEdApp*(obj: GPointer): GBoolean =
  gTypeCheckInstanceType(obj, typeNimEdApp)

proc lastActiveViewFromWidget(w: Widget): NimView =
  nimEdApp(gtk3.window(w.toplevel).application).lastActiveView

proc goto(view: var NimView; line, column: int; mark = false)

proc onSearchentrySearchChanged(entry: SearchEntry; userData: GPointer) {.exportc, cdecl.} =
  let win = nimEdAppWindow(entry.toplevel)
  var view: NimView = entry.lastActiveViewFromWidget
  let text = $entry.text
  var line: int
  #if scanf(text, ":$i$.", line):# and line >= 0: # will work for Nim > 0.14.2 only
  #  echo "mach", line
  if text[0] == ':' and text.len < 9: # avoid overflow trap
    let parsed = parseInt(text, line, start = 1)
    if parsed > 0 and parsed + 1 == text.len:# and line >= 0:
      goto(view, line, 0)
      return
  for i in LogLevel:
    if text == "--" & $i:
      win.loglevel = i
      return
  view.searchSettings.setSearchText(entry.text)
  let buffer = view.buffer
  var startIter, endIter, iter: TextIterObj
  buffer.getIterAtMark(iter, buffer.insert)
  if view.searchContext.forward(iter, startIter, endIter):
    discard view.scrollToIter(startIter, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5)

# 1.0. >> abs, int, biggestInt, ...
# current problem is, that we may get a lot of templates, see
# http://forum.nim-lang.org/t/2258#13769
# so we allow a few, but supress templates when too many...
proc getMethods(completionProvider: CompletionProvider; context: CompletionContext) {.cdecl.} =
  var startIter, endIter, iter: TextIterObj
  var proposals: GList
  var filteredProposals: GList
  var templates = 0
  if context.getIter(iter) and iter.backwardChar and iter.getChar == utf8GetChar("."):
    if context.activation == CompletionActivation.USER_REQUESTED:
      let provider = provider(completionProvider)
      let view: NimView = provider.win.lastActiveViewFromWidget
      let buffer= view.buffer
      buffer.getStartIter(startIter)
      buffer.getEndIter(endIter)
      let text = buffer.text(startIter, endIter, includeHiddenChars = true)
      let filepath: string = $view.buffer.path
      let dirtypath = saveDirty(filepath, text)
      free(text)
      if dirtypath != nil:
        let socket = newSocket()
        let ln = iter.line + 1
        let col = iter.lineIndex + 2 # 1 works too
        socket.connect("localhost", NSPort)
        socket.send("sug " & filepath & ";" & dirtypath & ":" & $ln & ":" & $col & "\c\L")
        let icon = providerGetIcon(provider)
        freeFull(provider.proposals, objectUnref)
        var line = newString(240)
        while true:
          socket.readLine(line)
          if line.len == 0: break
          ##if line == "\c\l": continue
          ##if line.startsWith("Hint"): continue # can occur in rare cases
          ##if not line.startsWith("sug"): continue # can occur in rare cases
          if line.find('\t') < 0: continue # that should catch all 3
          var com, sk, sym, sig, path, lin, col, doc, percent: string
          (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
          let unqualifiedSym = substr(sym, sym.find('.') + 1)
          let item: CompletionItem = newCompletionItemWithLabel(sym, unqualifiedSym, icon, sig)
          proposals = prepend(proposals, item)
          if sk == "skTemplate":
            inc(templates)
          else:
            filteredProposals = prepend(filteredProposals, item)
        provider.proposals = proposals
        socket.close
  if templates > 3:
    proposals = filteredProposals
  addProposals(context, completionProvider, proposals, finished = true)

proc providerIfaceInit(iface: CompletionProviderIface) =
  iface.getName = providerGetName
  iface.populate = getMethods
  iface.getPriority = providerGetPriority

proc providerDispose(gobject: GObject) {.cdecl.} =
  let self = provider(gobject)
  freeFull(self.proposals, objectUnref)
  self.proposals = nil
  var hhh = cast[GObject](self.icon)
  clearObject(hhh)
  self.icon = nil
  gObjectClass(providerParentClass).dispose(gobject)

proc providerFinalize(gobject: GObject) {.cdecl.} =
  let self = provider(gobject)
  free(self.name)
  self.name = nil
  gObjectClass(providerParentClass).finalize(gobject)

proc providerClassInit(klass: ProviderClass) =
  klass.dispose = providerDispose
  klass.finalize = providerFinalize

proc providerInit(self: Provider) = discard

# needs check
proc initCompletion*(view: gtksource.View; completion: gtksource.Completion; win: NimEdAppWindow) {.cdecl.} =
  var error: GError
  let wordProvider = newCompletionWords(nil, nil)
  register(wordProvider, view.getBuffer)
  discard addProvider(completion, wordProvider, error)
  objectSet(wordProvider, "priority", 10, nil)
  objectSet(wordProvider, "activation", CompletionActivation.USER_REQUESTED, nil)
  let nsProvider = provider(newObject(providerGetType(), nil))
  nsProvider.priority = 5
  nsProvider.win = win
  nsProvider.name = dup("Fixed Provider")
  discard addProvider(completion, nsProvider, error)

proc nimEdAppWindowSmartOpen(win: NimEdAppWindow; file: gio.GFile): NimView {.discardable.}

proc open(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  var dialog = newFileChooserDialog("Open File", nimEdAppWindow(app), FileChooserAction.OPEN,
                                    "Cancel", ResponseType.CANCEL, "Open", ResponseType.ACCEPT, nil);
  var res = dialog.run
  if res == ResponseType.ACCEPT.ord:
    var filename = fileChooser(dialog).filename
    let file: GFile = newFileForPath(filename)
    nimEdAppWindowSmartOpen(nimEdAppWindow(app), file)
    free(filename)
  dialog.destroy

proc removeMessageTimeout(p: GPointer): GBoolean {.cdecl.} =
  let win = nimEdAppWindow(p)
  acquire(statusLock)
  win.statusbar.remove(win.statusID1, win.messageID)
  release(statusLock)
  win.timeoutEventSourceID = 0
  return false

proc showmsg1(win: NimEdAppWindow; t: cstring) {.gcsafe.} =
  if tryAcquire(statusLock):
    win.statusbar.removeAll(win.statusID2)
    discard win.statusbar.push(win.statusID2, t)
    release(statusLock)

proc showmsg(win: NimEdAppWindow; t: cstring) =
  if win.timeoutEventSourceID != 0:
    discard sourceRemove(win.timeoutEventSourceID)
    win.timeoutEventSourceID = 0
    win.statusbar.remove(win.statusID1, win.messageID)
  win.messageID = win.statusbar.push(win.statusID1, t)
  win.timeoutEventSourceID = timeoutAddSeconds(5, removeMessageTimeout, win)

proc save(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  var startIter, endIter: TextIterObj
  let view: NimView = nimEdApp(nimEdAppWindow(app).getApplication).lastActiveView
  let buffer = view.buffer
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  let text = buffer.text(startIter, endIter, includeHiddenChars = true)
  var gerror: GError
  let gfile: GFile = newFileForPath(buffer.path) # never fails
  let res = gfile.replaceContents(text, len(text), etag = nil, makeBackup = false, GFileCreateFlags.NONE, newEtag = nil, cancellable = nil, gerror)
  objectUnref(gfile)
  if res:
    buffer.modified = false
  else:
    discard # error(gerror.message)

proc markTargetAction(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let win = nimEdAppWindow(app)
  let view: NimView = nimEdApp(win.getApplication).lastActiveView
  let scrolled: ScrolledWindow = scrolledWindow(view.parent)
  let notebook: Notebook = notebook(scrolled.parent)
  win.target = notebook

proc saveAsAction(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  var dialog = newFileChooserDialog("Save File", nimEdAppWindow(app), FileChooserAction.SAVE,
                                    "Cancel", ResponseType.CANCEL, "SAVE", ResponseType.ACCEPT, nil);
  var res = dialog.run
  let view: NimView = nimEdApp(nimEdAppWindow(app).getApplication).lastActiveView
  if res == ResponseType.ACCEPT.ord:
    var filename = fileChooser(dialog).filename
    view.buffer.path = filename.dup
    free(filename)
  dialog.destroy
  save(action, parameter, app)

proc findViewWithBuffer(views: GList; buffer: NimViewBuffer): NimView =
  var p: GList = views
  while p != nil:
    if nimView(p.data).buffer == buffer:
      return nimView(p.data)
    p = p.next

proc closetabAction(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let win = nimEdAppWindow(app)
  let view: NimView = nimEdApp(nimEdAppWindow(app).getApplication).lastActiveView
  let scrolled: ScrolledWindow = scrolledWindow(view.parent)
  let notebook: Notebook = notebook(scrolled.parent)
  let parent = container(notebook.parent)
  if notebook.nPages == 1 and not isPaned(parent): quit(win.getApplication); return
  notebook.remove(scrolled)

proc showErrorTooltip(w: Widget; x, y: cint; keyboardMode: GBoolean; tooltip: Tooltip; data: GPointer): GBoolean {.cdecl.} =
  var bx, by, trailing: cint
  var iter: TextIterObj
  if keyboardMode: return GFALSE
  let view: TextView = textView(w)
  view.windowToBufferCoords(TextWindowType.Widget, x, y, bx, by)
  let table: TextTagTable = view.buffer.tagTable
  var tag: TextTag = table.lookup(ErrorTagName)
  assert(tag != nil)
  discard view.getIterAtPosition(iter, trailing, bx, by)
  if iter.hasTag(tag):
    var e: ptr NimViewError
    var p: GList = nimView(w).errors
    while p != nil:
      e = cast[ptr NimViewError](p.data)
      tag = table.lookup($e.id)
      if tag != nil:
        if iter.hasTag(tag):
          tooltip.text = e.gs.str
          return GTRUE
      p = p.next
  return GFALSE

proc onGrabFocus(widget: Widget; userData: GPointer) {.cdecl.} =
  let win = nimEdAppWindow(userData)
  win.headerbar.subtitle = nimView(widget).buffer.path
  if win.headerbar.subtitle.isNil:
    win.headerbar.title = "Unsaved"
  else:
    win.headerbar.title = glib.basename(win.headerbar.subtitle) # deprecated, no copy
  nimEdApp(gtk3.window(widget.toplevel).application).lastActiveView = nimView(widget)

proc closeTab(button: Button; userData: GPointer) {.cdecl.} =
  let win = nimEdAppWindow(button.toplevel)
  let notebook: Notebook = notebook(button.parent.parent)
  let scrolled: ScrolledWindow = scrolledWindow(userData)
  let parent = container(notebook.parent)
  if notebook.nPages == 1 and not isPaned(parent): quit(win.getApplication); return
  notebook.remove(scrolled)

proc onBufferModified(textBuffer: TextBuffer; userData: GPointer) {.cdecl.} =
  var l: Label = label(userdata)
  var s: string
  let h = nimViewBuffer(textBuffer).path
  if h.isNil:
    s = "Unsaved"
  else:
    s = ($h).extractFilename
  if textBuffer.modified:
    s.insert("*")
  l.text = s

proc advanceErrorWord(ch: GUnichar, userdata: Gpointer): GBoolean {.cdecl.} = gNot(isalnum(ch))

proc markLocation(view: var NimView; ln, cn: int) =
  var startIter, endIter, iter: TextIterObj
  view.freeErrors
  let buffer: gtksource.Buffer = gtksource.buffer(view.getBuffer)
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  buffer.removeTagByName(ErrorTagName, startIter, endIter)
  for i in 0 .. MaxErrorTags:
    buffer.removeTagByName($i, startIter, endIter)
  buffer.removeSourceMarks(startIter, endIter, NullStr)
  view.showLinemarks = false
  var attrs = newMarkAttributes()
  var color = RGBAObj(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.2)
  attrs.background = color
  attrs.iconName = "list-remove"
  view.setMarkAttributes(ErrorTagName, attrs, priority = 1)
  objectUnref(attrs)
  buffer.getIterAtLineIndex320(startIter, ln.cint, cn.cint)
  iter = startIter
  if iter.line == 0:
    discard iter.backwardLine
  else:
    discard iter.backwardLine
    discard iter.forwardLine
  discard iter.forwardChar
  discard buffer.createSourceMark(NullStr, ErrorTagName, iter)
  let tag: TextTag = buffer.tagTable.lookup(ErrorTagName)
  assert(tag != nil)
  discard startiter.backwardChar
  if startIter.hasTag(tag):
    discard startIter.forwardToTagToggle(tag)
  discard startiter.forwardChar
  endIter = startIter
  iter = startIter
  discard iter.forwardToLineEnd
  discard endIter.forwardChar
  discard endIter.forwardFindChar(advanceErrorWord, userData = nil, limit = iter)
  buffer.applyTag(tag, startIter, endIter)
  view.showLinemarks = true

proc scrollTo(view: var NimView; line: cint = 0; column: cint = 0) =
  var iter: TextIterObj
  if line > 1:
    let buffer = nimViewBuffer(view.getBuffer)
    buffer.getIterAtLineIndex(iter, line - 1, column - 1)
    buffer.placeCursor(iter)
    if view.idleScroll == 0:
      view.idleScroll = idleAdd(GSourceFunc(scrollToCursor), view)
    markLocation(view, line - 1, column - 1)

proc fixUnnamed(buffer: NimViewBuffer; name: cstring) =
  let language: gtksource.Language = languageManagerGetDefault().guessLanguage(name, nil)
  buffer.setLanguage(language)

proc loadContent(file: GFile; buffer: NimViewBuffer; settings: GSettings) =
  var
    startIter, endIter: TextIterObj
    contents: cstring
    length: Gsize
    error: GError
  if file != nil and loadContents(file, cancellable = nil, contents, length, etagOut = nil, error):
    buffer.setText(contents, length.cint)
    free(contents)
    buffer.setPath(file.path)
  buffer.modified = false

proc getMapping(value: var GValueObj; variant: GVariant; userData: GPointer): GBoolean {.cdecl.} =
  let b = variant.getBoolean
  setEnum(value, b.cint)
  return GTRUE

proc updateLabelOccurrences(label: Label; pspec: GParamSpec; userData: GPointer) {.cdecl.} =
  var selectStart, selectEnd: TextIterObj
  var text: cstring
  let context = searchContext(userData)
  let buffer = context.buffer
  let occurrencesCount = context.getOccurrencesCount
  discard buffer.getSelectionBounds(selectStart, selectEnd)
  let occurrencePos = context.getOccurrencePosition(selectStart, selectEnd)
  if occurrencesCount <= 0:
    text = dup("")
  elif occurrencePos == -1:
    text = dupPrintf("%d occurrences", occurrencesCount)
  else:
    text = dupPrintf("%d of %d", occurrencePos, occurrencesCount)
  label.text = text
  free(text)

proc findLogView(views: GList): NimView =
  var p: GList = views
  while p != nil:
    if glib.basename(nimView(p.data).buffer.path) == "log.txt":
      return nimView(p.data)
    p = p.next

proc log(win: NimEdAppWindow; msg: cstring; level = LogLevel.log) =
  if level.ord < win.logLevel.ord: return
  let view = findLogView(win.views)
  if not view.isNil:
    let buffer = view.buffer
    var iter: TextIterObj
    buffer.getEndIter(iter)
    buffer.insert(iter, msg, -1)
    buffer.insert(iter, "\n", -1)
    discard view.scrollToIter(iter, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5)

proc onDestroyNimView(obj: Widget; userData: GPointer) {.cdecl.} =
  let win = nimEdAppWindow(userData)
  let app = nimEdApp(win.getApplication)
  if not app.isNil: # yes this happens for last view!
    if app.lastActiveView == obj:
      app.lastActiveView = if win.views.isNil: nil else: nimView(win.views.data)
  var v = nimView(obj)
  var b = v.buffer
  win.views = win.views.remove(v)
  if findViewWithBuffer(win.views, b).isNil:
    win.buffers = win.buffers.remove(b)

proc onCursorMoved(obj: GObject; pspec: GParamSpec; userData: Gpointer) {.cdecl.} =
  let win = nimEdAppWindow(userData)
  let buffer = nimViewBuffer(obj)
  var last {.global.}: cstring = nil
  var lastline {.global.}: cint = -1
  var text: cstring
  var msg: StatusMsg
  var startIter, endIter, iter: TextIterObj
  #obj.signalHandlerBlock(buffer.handlerID) # this will crash for fast backspace, even with gSignalConnectAfter()
  #while gtk3.eventsPending(): echo "mainIteration"; discard gtk3.mainIteration()
  #obj.signalHandlerUnblock(buffer.handlerID)
  buffer.getIterAtMark(iter, buffer.insert)
  text = dupPrintf("%d, %d", iter.line + 1, iter.lineIndex)
  win.statuslabel.text = text
  free(text)
  text = nil
  msg.line = iter.line + 1
  msg.column = iter.lineIndex + 1 # we need this + 1
  if not iter.insideWord or iter.getBytesInLine < 3:
    msg.filepath = ""
    channel.send(msg)
    return
  startIter = iter
  endIter = iter
  if not startIter.startsWord: discard startIter.backwardWordStart
  if not endIter.endsWord: discard endIter.forwardWordEnd
  free(text)
  text = getText(startIter, endIter)
  if iter.line == lastline and text == last:
    return
  lastline = iter.line
  free(last)
  last = text
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  text = buffer.text(startIter, endIter, includeHiddenChars = true)
  msg.filepath = $buffer.path
  msg.dirtypath = saveDirty(msg.filepath, text)
  free(text)
  if msg.dirtyPath.isNil: return
  channel.send(msg)

proc addViewToNotebook(win: NimEdAppWindow; notebook: Notebook; file: gio.GFile = nil, buf: NimViewBuffer = nil): NimView =
  var
    buffer: NimViewBuffer
    view: NimView
    name: cstring
  if not file.isNil:
    name = file.basename # we have to call free!
  let scrolled: ScrolledWindow = newScrolledWindow(nil, nil)
  scrolled.hexpand = true
  scrolled.vexpand = true
  let language: gtksource.Language = if file.isNil: nil else: languageManagerGetDefault().guessLanguage(name, nil)
  buffer = if buf.isNil: newNimViewBuffer(language) else: buf
  #echo "refcount"
  #echo buffer.refCount
  view = newNimView(buffer)
  discard gSignalConnect(view, "destroy", gCallback(onDestroyNimView), win)
  #echo buffer.refCount
  `bind`(win.settings, "showlinenumbers", view, "show-line-numbers", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "scrollbaroverlay", scrolled, "overlay-scrolling", gio.GSettingsBindFlags.GET)
  bindWithMapping(win.settings, "scrollbarautomatic", scrolled, "vscrollbar-policy", gio.GSettingsBindFlags.GET, getMapping, nil, nil, nil)
  bindWithMapping(win.settings, "scrollbarautomatic", scrolled, "hscrollbar-policy", gio.GSettingsBindFlags.GET, getMapping, nil, nil, nil)
  let fontDesc = fontDescriptionFromString(getString(win.settings, "font"))
  view.modifyFont(fontDesc)
  free(fontDesc);
  if buf.isNil:
    win.buffers = glib.prepend(win.buffers, buffer)
    win.views = glib.prepend(win.views, view)
    discard buffer.createTag(ErrorTagName, "underline", pango.Underline.Error, nil)
    discard buffer.createTag(HighlightTagName, "background", win.searchMatchBg, "foreground", win.searchMatchFg, nil)
    for i in 0 .. MaxErrorTags:
      discard buffer.createTag($i, nil)
    if not file.isNil:
      buffer.setPath(file.path)
  view.hasTooltip = true
  discard gSignalConnect(view, "query-tooltip", gCallback(showErrorTooltip), nil)
  discard gSignalConnect(view, "grab_focus", gCallback(onGrabFocus), win)
  let completion: Completion = getCompletion(view)
  initCompletion(view, completion, win)
  scrolled.add(view)
  scrolled.showAll
  # from 3.20 gedit-documents-panel.c
  let closeButton = button(newObject(typeButton, "relief", ReliefStyle.NONE, "focus-on-click", false, nil))
  let context = closeButton.getStyleContext
  context.addClass("flat")
  context.addClass("small-button")
  let icon = newThemedIconWithDefaultFallbacks("window-close-symbolic")
  let image: Image = newImage(icon, IconSize.MENU)
  objectUnref(icon)
  closeButton.add(image)
  discard gSignalConnect(closeButton, "clicked", gCallback(closeTab), scrolled)
  let label = newLabel(if file.isNil: "Unsaved".cstring else: name)
  view.label = label
  label.ellipsize = pango.EllipsizeMode.END
  label.halign = Align.START
  label.valign = Align.CENTER
  discard gSignalConnect(buffer, "modified-changed", gCallback(onBufferModified), label)
  if buf.isNil:
    buffer.handlerID = gSignalConnect(buffer, "notify::cursor-position", gCallback(onCursorMoved), win)
  let box = newBox(Orientation.HORIZONTAL, spacing = 0)
  box.packStart(label, expand = true, fill = false, padding = 0)
  box.packStart(closeButton, expand = false, fill = false, padding = 0)
  box.showAll
  let pageNum = notebook.appendPage(scrolled, box)
  notebook.setTabReorderable(scrolled, true)
  notebook.setTabDetachable(scrolled, true)
  notebook.setGroupName("stefan")
  notebook.currentPage = pageNum
  notebook.childSet(scrolled, "tab-expand", true, nil)
  if buf.isNil:
    loadContent(file, buffer, win.settings)
    let scheme: cstring  = getString(win.settings, StyleSchemeSettingsID)
    if scheme != nil:
      let manager = styleSchemeManagerGetDefault()
      let style = getScheme(manager, scheme)
      buffer.setStyleScheme(style)
  view.searchSettings = newSearchSettings()
  view.searchContext = newSearchContext(buffer, view.searchSettings)
  `bind`(win.settings, "casesensitive", view.searchSettings, "case-sensitive", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "regexenabled", view.searchSettings, "regex-enabled", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "wraparound", view.searchSettings, "wrap-around", gio.GSettingsBindFlags.GET)
  `bind`(win.settings, "wordboundaries", view.searchSettings, "at-word-boundaries", gio.GSettingsBindFlags.GET)
  discard gSignalConnectSwapped(view.searchContext, "notify::occurrences-count", gCallback(updateLabelOccurrences), win.searchcountlabel)
  free(name)
  return view

proc pageNumChanged(notebook: Notebook; child: Widget; pageNum: cuint; userData: GPointer) {.cdecl.} =
  let win = nimEdAppWindow(userData)
  win.statuslabel.text = ""
  notebook.showTabs = notebook.getNPages > 1 or getBoolean(win.settings, "showtabs")
  if notebook.nPages == 0:
    let parent = container(notebook.parent)
    if not isPaned(parent): return
    var c1 = paned(parent).child1
    var c2 = paned(parent).child2
    if notebook == c1: swap(c1, c2)
    discard c1.objectRef
    parent.remove(c1)
    parent.remove(c2)
    let pp = container(parent.parent)
    pp.remove(parent)
    pp.add(c1)
    if isPaned(pp):
      pp.childSet(c1, "shrink", false, nil)
    c1.objectUnref

proc getMappingTabs(value: var GValueObj; variant: GVariant; userData: GPointer): GBoolean {.cdecl.} =
  let notebook = notebook(userData)
  let b = variant.getBoolean or notebook.getNPages > 1
  setBoolean(value, b)
  return GTRUE

proc split(app: Gpointer; o: Orientation) =
  let win = nimEdAppWindow(app)
  let view: NimView = nimEdApp(win.getApplication).lastActiveView
  let buffer: NimViewBuffer = view.buffer
  let scrolled: ScrolledWindow = scrolledWindow(view.parent)
  let notebook: Notebook = notebook(scrolled.parent)
  var allocation: AllocationObj
  notebook.getAllocation(allocation)
  let posi = (if o == Orientation.HORIZONTAL: allocation.width else: allocation.height) div 2
  let parent = container(notebook.parent)
  discard notebook.objectRef
  parent.remove(notebook)
  let paned: Paned = newPaned(o)
  paned.pack1(notebook, resize = true, shrink = false)
  let newbook = newNotebook()
  discard gSignalConnect (newbook, "page-added", gCallback(pageNumChanged), win)
  discard gSignalConnect (newbook, "page-removed", gCallback(pageNumChanged), win)
  bindWithMapping(win.settings, "showtabs", newbook, "show-tabs", gio.GSettingsBindFlags.GET, getMappingTabs, nil, newbook, nil)
  discard addViewToNotebook(win = nimEdAppWindow(app), notebook = newbook, file = nil)
  paned.pack2(newbook, resize = true, shrink = false)
  paned.position = posi
  parent.add(paned)
  parent.show_all
  notebook.objectUnref

proc hsplit(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  split(app, Orientation.HORIZONTAL)

proc vsplit(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  split(app, Orientation.VERTICAL)

var winAppEntries = [
  gio.GActionEntryObj(name: "hsplit", activate: hsplit, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "vsplit", activate: vsplit, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "save", activate: save, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "closetabAction", activate: closetabAction, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "saveAsAction", activate: saveAsAction, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "markTargetAction", activate: markTargetAction, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "open", activate: open, parameterType: nil, state: nil, changeState: nil)]

proc settingsChanged(settings: gio.GSettings; key: cstring; win: NimEdAppWindow) {.cdecl.} =
  let manager = styleSchemeManagerGetDefault()
  let style = getScheme(manager, getString(settings, key))
  if style != nil:
    var p: GList = win.buffers
    while p != nil:
      gtksource.buffer(p.data).setStyleScheme(style)
      p = p.next

proc fontSettingChanged(settings: gio.GSettings; key: cstring; win: NimEdAppWindow) {.cdecl.} =
  let fontDesc = fontDescriptionFromString(getString(win.settings, key))
  var p: GList = win.views
  while p != nil:
    nimView(p.data).modifyFont(fontDesc)
    p = p.next
  free(fontDesc);

# TODO: check
proc nimEdAppWindowInit(self: NimEdAppWindow) =
  var
    builder: Builder
    menu: gio.GMenuModel
    action: gio.GAction
  initTemplate(self)
  self.settings = newSettings("org.gtk.ned")
  discard gSignalConnect(self.settings, "changed::styleschemesettingsid",
                   gCallback(settingsChanged), self)
  discard gSignalConnect(self.settings, "changed::fontsettingsid",
                   gCallback(fontSettingChanged), self)
  builder = newBuilder(resourcePath = "/org/gtk/ned/gears-menu.ui")
  menu = gMenuModel(getObject(builder, "menu"))
  setMenuModel(self.gears, menu)
  objectUnref(builder)
  addActionEntries(gio.gActionMap(self), addr winAppEntries[0], cint(len(winAppEntries)), self)
  objectSet(settingsGetDefault(), "gtk-shell-shows-app-menu", true, nil)
  setShowMenubar(self, true)

proc nimEdAppWindowDispose(obj: GObject) {.cdecl.} =
  let win = nimEdAppWindow(obj)
  if win.timeoutEventSourceID != 0:
    discard sourceRemove(win.timeoutEventSourceID)
    win.timeoutEventSourceID = 0
    win.statusbar.remove(win.statusID1, win.messageID)
  gObjectClass(nimEdAppWindowParentClass).dispose(obj)

proc nimEdAppWindowClassInit(klass: NimEdAppWindowClass) =
  klass.dispose = nimEdAppWindowDispose
  setTemplateFromResource(klass, "/org/gtk/ned/window.ui")
  widgetClassBindTemplateChild(klass, NimEdAppWindow, gears)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, searchentry)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, entry)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, searchcountlabel)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, statuslabel)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, headerbar)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, statusbar)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, savebutton)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, openbutton)
  widgetClassBindTemplateChild(klass, NimEdAppWindow, grid)

proc nimEdAppWindowNew*(app: NimEdApp): NimEdAppWindow =
  nimEdAppWindow(newObject(typeNimEdAppWindow, "application", app, nil))

# Here we use a type with private component. This is mainly to test and
# demonstrate that it works. Generally putting new fields into
# NedAppPrefsObj as done for the types above is simpler.
type
  NedAppPrefs* = ptr NedAppPrefsObj
  NedAppPrefsObj = object of gtk3.DialogObj

  NedAppPrefsClass = ptr NedAppPrefsClassObj
  NedAppPrefsClassObj = object of gtk3.DialogClassObj

  NedAppPrefsPrivate = ptr NedAppPrefsPrivateObj
  NedAppPrefsPrivateObj = object
    settings: gio.GSettings
    font: gtk3.Widget
    showtabs: gtk3.Widget
    showlinenumbers: gtk3.Widget
    casesensitive: gtk3.Widget
    regexenabled: gtk3.Widget
    wraparound: gtk3.Widget
    wordboundaries: gtk3.Widget
    reusedefinition: gtk3.Widget
    scrollbarautomatic: gtk3.Widget
    scrollbaroverlay: gtk3.Widget
    style: gtk3.Widget
    buffer: gtksource.Buffer
    styleScheme: gtksource.StyleScheme

gDefineTypeWithPrivate(NedAppPrefs, dialogGetType())

template typeNedAppPrefs*(): expr = nedAppPrefsGetType()

proc nedAppPrefs(obj: GObject): NedAppPrefs =
  gTypeCheckInstanceCast(obj, nedAppPrefsGetType(), NedAppPrefsObj)

proc isNedAppPrefs*(obj: GObject): GBoolean =
  gTypeCheckInstanceType(obj, typeNedAppPrefs)

proc styleSchemeChanged(sscb: StyleSchemeChooserButton, pspec: GParamSpec, settings: gio.GSettings) {.cdecl.} =
  discard settings.setString(StyleSchemeSettingsID, styleSchemeChooser(sscb).getStyleScheme.id)

proc fontChanged(fbcb: FontButton, pspec: GParamSpec, settings: gio.GSettings) {.cdecl.} =
  discard settings.setString(FontSettingsID, fontButton(fbcb).getFontName)

proc nedAppPrefsInit(self: NedAppPrefs) =
  let priv: NedAppPrefsPrivate = nedAppPrefsGetInstancePrivate(self)
  initTemplate(self)
  priv.settings = newSettings("org.gtk.ned")
  `bind`(priv.settings, "font", priv.font, "font", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, StyleSchemeSettingsID, priv.style, "label", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "showtabs", priv.showtabs, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "reusedefinition", priv.reusedefinition, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "showlinenumbers", priv.showlinenumbers, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "casesensitive", priv.casesensitive, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "regexenabled", priv.regexenabled, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "wordboundaries", priv.wordboundaries, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "wraparound", priv.wraparound, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "scrollbaroverlay", priv.scrollbaroverlay, "active", gio.GSettingsBindFlags.DEFAULT)
  `bind`(priv.settings, "scrollbarautomatic", priv.scrollbarautomatic, "active", gio.GSettingsBindFlags.DEFAULT)
  discard gSignalConnect(priv.style, "notify::style-scheme", gCallback(styleSchemeChanged), priv.settings)
  discard gSignalConnect(priv.font, "notify::font", gCallback(fontChanged), priv.settings)

proc nedAppPrefsDispose(obj: gobject.GObject) {.cdecl.} =
  let priv: NedAppPrefsPrivate = nedAppPrefsGetInstancePrivate(nedAppPrefs(obj))
  clearObject(GObject(priv.settings))
  priv.settings = nil # https://github.com/nim-lang/Nim/issues/3449
  gObjectClass(nedAppPrefsParentClass).dispose(obj)

proc nedAppPrefsClassInit(klass: NedAppPrefsClass) =
  klass.dispose = nedAppPrefsDispose
  setTemplateFromResource(klass, "/org/gtk/ned/prefs.ui")
  # we may replace function call above by this code to avoid use of resource:
  #var
  #  buffer: cstring
  #  length: gsize
  #  error: glib.GError = nil
  #  gbytes: glib.GBytes = nil
  #if not gFileGetContents("prefs.ui", buffer, length, error):
  #  gCritical("Unable to load prefs.ui \'%s\': %s", gObjectClassName(klass), error.message)
  #  free(error)
  #  return
  #gbytes = gBytesNew(buffer, length)
  #setTemplate(klass, gbytes)
  #gFree(buffer)
  # done
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, font)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, showtabs)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, reusedefinition)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, showlinenumbers)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, casesensitive)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, regexenabled)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, wordboundaries)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, wraparound)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, scrollbaroverlay)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, scrollbarautomatic)
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, style)

proc nedAppPrefsNew*(win: NimEdAppWindow): NedAppPrefs =
  nedAppPrefs(newObject(typeNedAppPrefs, "transient-for", win, "use-header-bar", true, nil))

proc preferencesActivated(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let win: gtk3.Window = getActiveWindow(application(app))
  let prefs: NedAppPrefs = nedAppPrefsNew(nimEdAppWindow(win))
  present(prefs)

proc setVisibleChild(nb: Notebook; c: Widget): bool =
  var i: cint = 0
  var w: Widget
  while true:
    w = nb.getNthPage(i)
    if w.isNil: break
    if w == c:
      nb.setCurrentPage(i)
      return true
    inc(i)
  return false

proc setVisibleChildName(nb: Notebook; n: cstring): bool =
  var i: cint = 0
  var w: Widget
  while true:
    w = nb.getNthPage(i)
    if w.isNil: break
    if w.name == n:
      nb.setCurrentPage(i)
      return true
    inc(i)
  return false

proc setVisibleViewName(nb: Notebook; n: cstring): NimView =
  var i: cint = 0
  var w: Widget
  while true:
    w = nb.getNthPage(i)
    if w.isNil: break
    if scrolledWindow(w).child.name == n:
      nb.setCurrentPage(i)
      return nimView(scrolledWindow(w).child)
    inc(i)
  return nil

proc findViewWithPath(views: GList; path: cstring): NimView =
  var p: GList = views
  while p != nil:
    if nimView(p.data).buffer.path == path:
      return nimView(p.data)
    p = p.next

proc findViewWithDef(views: GList): NimView =
  var p: GList = views
  while p != nil:
    if nimView(p.data).buffer.defView:
      return nimView(p.data)
    p = p.next

proc findBufferWithPath(buffers: GList; path: cstring): NimViewBuffer =
  var p: GList = buffers
  while p != nil:
    if nimViewBuffer(p.data).path == path:
      return nimViewBuffer(p.data)
    p = p.next

proc nimEdAppWindowDefOpen(win: NimEdAppWindow; file: gio.GFile): NimView =
  var
    view: NimView
    notebook: Notebook
  view = findViewWithPath(win.views, file.path)
  if not view.isNil: return view
  if win.settings.getBoolean("reusedefinition"):
    view = findViewWithDef(win.views)
  if view.isNil:
    view = findViewWithPath(win.views, nil) # "Unused" buffer
    if view.isNil or view.buffer.charCount > 0:
      view = nil
    else:
      fixUnnamed(view.buffer, file.basename)
  if not view.isNil:
    loadContent(file, view.buffer, win.settings)
  else:
    if win.target.isNil:
      let lastActive: NimView = nimEdApp(win.getApplication).lastActiveView
      if lastActive.isNil: # currently lastActive is always valid
        let grid: Grid = win.grid
        notebook = gtk3.notebook(grid.childAt(0, 1))
      else:
        notebook = gtk3.notebook(lastActive.parent.parent)
    else:
      notebook = win.target
    view = addViewToNotebook(win, notebook, file, buf = nil)
  return view

# support new view for old buffer
proc nimEdAppWindowSmartOpen(win: NimEdAppWindow; file: gio.GFile): NimView =
  var
    view: NimView
    buffer: NimViewBuffer
    notebook: Notebook
  view = findViewWithPath(win.views, file.path)
  if not view.isNil:
    buffer = view.buffer # multi view
  let lastActive: NimView = nimEdApp(win.getApplication).lastActiveView
  if lastActive.isNil:
    let grid: Grid = win.grid
    notebook = gtk3.notebook(grid.childAt(0, 1))
  else:
    notebook = gtk3.notebook(lastActive.parent.parent)
  if not lastActive.isNil and lastActive.buffer.path.isNil and lastActive.buffer.charCount == 0:
    view = lastActive
    fixUnnamed(view.buffer, file.basename)
    if buffer.isNil:
      loadContent(file, view.buffer, win.settings)
    else:
      view.setBuffer(buffer)
      view.label.text = basename(buffer.path)
      discard gSignalConnect(buffer, "modified-changed", gCallback(onBufferModified), view.label)
  else:
    view = addViewToNotebook(win, notebook, file, buffer)
    if lastActive.isNil:
      nimEdApp(gtk3.window(win.toplevel).application).lastActiveView = view
      var iter: TextIterObj
      view.buffer.getIterAtLineIndex(iter, 0, 0) # put cursor somewhere, so search entry works from the beginning
      view.buffer.placeCursor(iter)
  return view

proc quitActivated(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  quit(application(app))

proc winFromApp(app: Gpointer): NimEdAppWindow =
  let windows: GList = application(app).windows
  if not windows.isNil: return nimEdAppWindow(windows.data)


proc gotoMark(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer; forward: bool) =
  let win = winFromApp(app)
  if win.isNil: return
  let view: NimView = nimEdApp(app).lastActiveView
  let buffer: NimViewBuffer = nimViewBuffer(view.getBuffer)
  var iter: TextIterObj
  buffer.getIterAtMark(iter, buffer.insert)
  win.searchcountlabel.text = ""
  win.entry.text = ""
  let cat = NullStr # UseCat, ErrorCat
  let wrap = win.settings.getBoolean("wraparound")
  if forward:
    if not buffer.forwardIterToSourceMark(iter, cat):
      if wrap: buffer.getStartIter(iter)
  else:
    if not buffer.backwardIterToSourceMark(iter, cat):
      if wrap: buffer.getEndIter(iter)
  buffer.placeCursor(iter)
  discard view.scrollToIter(iter, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5)
  ### view.scrollToMark(buffer.insert, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5) # work also

proc gotoNextMark(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  gotoMark(action, parameter, app, true)

proc gotoPrevMark(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  gotoMark(action, parameter, app, false)

proc onmatch(entry: SearchEntry; userData: GPointer; nxt: bool) =
  var iter, matchStart, matchEnd: TextIterObj
  let view = lastActiveViewFromWidget(entry)
  let win = nimEdAppWindow(view.toplevel)
  let buffer: gtksource.Buffer = gtksource.buffer(view.getBuffer)
  buffer.getIterAtMark(iter, buffer.insert)
  if (if nxt: view.searchContext.forward(iter, matchStart, matchEnd) else: view.searchContext.backward(iter, matchEnd, matchStart)):
    buffer.selectRange(matchEnd, matchStart)
    view.scrollToMark(buffer.insert, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5)
    updateLabelOccurrences(win.searchcountlabel, nil, view.searchContext)

proc onnextmatch(entry: SearchEntry; userData: GPointer) {.exportc, cdecl.} =
  onmatch(entry, userData, true)

proc onprevmatch(entry: SearchEntry; userData: GPointer) {.exportc, cdecl.} =
  onmatch(entry, userData, false)

proc searchentryactivate(entry: SearchEntry; userData: GPointer) {.exportc, cdecl.} =
  let view = lastActiveViewFromWidget(entry)
  view.grabFocus

proc activateSearchEntry(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let win = winFromApp(app)
  win.searchEntry.grabFocus

proc findNP(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer; next: bool) =
  var iter, matchStart, matchEnd: TextIterObj
  let view: NimView = nimEdApp(app).lastActiveView
  let win = nimEdAppWindow(view.toplevel)
  let buffer: gtksource.Buffer = gtksource.buffer(view.getBuffer)
  buffer.getIterAtMark(iter, buffer.insert)
  if next and view.searchContext.forward(iter, matchStart, matchEnd) or
    not next and view.searchContext.backward(iter, matchStart, matchEnd):
    if next:
      buffer.selectRange(matchEnd, matchStart)
    else:
      echo "findPrev"
      buffer.selectRange(matchStart, matchEnd)
    view.scrollToMark(buffer.insert, withinMargin = 0.2, useAlign = true, xalign = 1, yalign = 0.5)
    updateLabelOccurrences(win.searchcountlabel, nil, view.searchContext)

proc findNext(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  findNP(action, parameter, app, true)

proc findPrev(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  findNP(action, parameter, app, false)

proc find(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  var iter, startIter, endIter: TextIterObj
  let view: NimView = nimEdApp(app).lastActiveView
  let buffer: gtksource.Buffer = gtksource.buffer(view.getBuffer)
  if not buffer.getSelectionBounds(startIter, endIter):
    buffer.getIterAtMark(startIter, buffer.insert)
    endIter = startIter
    if not startIter.startsWord: discard startIter.backwardWordStart
    if not endIter.endsWord: discard endIter.forwardWordEnd
  var text: cstring = getText(startIter, endIter)
  let t = view.searchSettings.getSearchText()
  if t != nil and t == text: text = nil
  view.searchSettings.setSearchText(text)

proc goto(view: var NimView; line, column: int; mark = false) =
  var iter: TextIterObj
  let scrolled: ScrolledWindow = scrolledWindow(view.parent)
  let notebook: Notebook = notebook(scrolled.parent)
  let buffer = view.buffer
  notebook.setCurrentPage(notebook.pageNum(scrolled))
  buffer.getIterAtLineIndex(iter, line.cint, column.cint)
  buffer.placeCursor(iter)
  if view.idleScroll == 0:
    view.idleScroll = idleAdd(GSourceFunc(scrollToCursor), view)
  if mark: markLocation(view, line, column)

proc showData(win: NimEdAppWindow) {.thread gcsafe.} =
  var line = newStringOfCap(240)
  var msg, h: StatusMsg
  sleep(3000)
  while true:
    msg = channel.recv()
    var b: bool
    while true:
      (b, h) = channel.tryRecv()
      if b:
        if not msg.dirtypath.isNil:
          msg.dirtypath.removeFile
        msg = h
      else:
        break
    if msg.filepath.isNil: break
    if msg.filepath == "":
      showmsg1(win, "")
      continue
    let socket = newSocket()
    socket.connect("localhost", NSPort)
    var com, sk, sym, sig, path, lin, col, doc, percent: string
    socket.send("def " & msg.filepath & ";" & msg.dirtypath & ":" & $msg.line & ":" & $msg.column & "\c\L")
    sym = nil
    while true:
      socket.readLine(line)
      if line.len == 0: break
      if line.find('\t') < 0: continue
      (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
      #echo line
    if sym.isNil:
      showmsg1(win, "")
    else:
      if doc == "\"\"": doc = ""
      if path == msg.filepath: path = ""
      showmsg1(win, sk[2..^1] & ' ' & sym & ' ' & sig & " (" & path & ' ' & lin & ", " & col & ") " & doc)
    socket.close
    msg.dirtypath.removeFile
    sleep(500)

proc con(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  echo "con"
  var lines {.global.}: array[8, string]
  var linecounter {.global.}: int = 0
  var totallines {.global.}: int = 0
  var startIter, endIter, iter: TextIterObj
  let windows: GList = application(app).windows
  if windows.isNil: return
  let win: NimEdAppWindow = nimEdAppWindow(windows.data)
  if linecounter == 0:
    let view: NimView = nimEdApp(app).lastActiveView
    let buffer: gtksource.Buffer = gtksource.buffer(view.getBuffer)
    buffer.getStartIter(startIter)
    buffer.getEndIter(endIter)
    let text = buffer.text(startIter, endIter, includeHiddenChars = true)
    let filepath: string = $view.buffer.path
    let dirtypath = saveDirty(filepath, text)
    if dirtyPath.isNil: return
    var line = newStringOfCap(240)
    let socket = newSocket()
    socket.connect("localhost", NSPort)
    buffer.getIterAtMark(iter, buffer.insert)
    let ln = iter.line + 1
    let column = iter.lineIndex + 1
    echo filepath
    echo dirtyPath
    socket.send("con " & filepath & ";" & dirtypath & ":" & $ln & ":" & $column & "\c\L")
    var com, sk, sym, sig, path, lin, col, doc, percent: string
    while true:
      socket.readLine(line)
      if line.len == 0: break
      if line.find('\t') < 0: continue
      echo line
      log(win, line)
      (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
      if linecounter < 8:
        lines[linecounter] = sym & ' ' & sig & ' ' & path & " (" & lin & ", " & col & ")"
        inc linecounter
    socket.close
    dirtypath.removeFile
    totallines = linecounter
  if linecounter > 0:
    let h = if totallines > 1: $(totallines - linecounter + 1) & '/' & $totallines else: ""
    showmsg1(win, lines[totallines - linecounter] & ' ' & h)
    dec linecounter

proc gotoDef(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  echo "gotoDef"
  var startIter, endIter, iter: TextIterObj
  let windows: GList = application(app).windows
  if windows.isNil: return
  let win: NimEdAppWindow = nimEdAppWindow(windows.data)
  let view: NimView = nimEdApp(app).lastActiveView
  let buffer: gtksource.Buffer = gtksource.buffer(view.getBuffer)
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  let text = buffer.text(startIter, endIter, includeHiddenChars = true)
  let filepath: string = $view.buffer.path
  let dirtypath = saveDirty(filepath, text)
  if dirtyPath.isNil: return
  var line = newStringOfCap(240)
  let socket = newSocket()
  socket.connect("localhost", NSPort)
  buffer.getIterAtMark(iter, buffer.insert)
  let ln = iter.line + 1
  let column = iter.lineIndex + 1
  echo filepath
  echo dirtyPath
  socket.send("def " & filepath & ";" & dirtypath & ":" & $ln & ":" & $column & "\c\L")
  var com, sk, sym, sig, path, lin, col, doc, percent: string
  while true:
    socket.readLine(line)
    if line.isNil:
      echo "line.isNil"
      break
    if line.len == 0: break
    if line == "\c\l": continue
    echo line
    log(win, line)
    (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
    echo line, " ", strutils.parseInt(lin).cint - 1, ' ', strutils.parseInt(col).cint - 1
  socket.close
  dirtypath.removeFile
  echo path
  if path.isNil:
    showmsg(win, "Nil")
    return
  let file: GFile = newFileForPath(path)
  var newView = nimEdAppWindowDefOpen(win, file)
  newView.buffer.defView = true
  goto(newView, strutils.parseInt(lin) - 1, strutils.parseInt(col))

proc useorrep(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer; rep: bool) =
  let win = winFromApp(app)
  if win.isNil: return
  let entry = win.entry
  let view: NimView = nimEdApp(app).lastActiveView
  let buffer: NimViewBuffer = nimViewBuffer(view.getBuffer)
  let tag: TextTag = buffer.tagTable.lookup(HighlightTagName)
  var startIter, endIter, iter: TextIterObj
  var ln, cn: int
  var fix: string
  var replen {.global.}: int
  var pathcheck: string
  var multiMod: bool
  win.searchEntry.text = "" # may be confusing
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  iter = startIter
  if buffer.forwardIterToSourceMark(iter, UseCat) or buffer.backwardIterToSourceMark(iter, UseCat): # marks set
    buffer.removeTag(tag, startIter, endIter)
    if rep and replen > 0: # we intent to replace, and have prepaired for that
      let sub = entry.getText
      let subLen = sub.len.cint
      buffer.signalHandlerBlock(buffer.handlerID)
      while buffer.forwardIterToSourceMark(startIter, UseCat) or startIter.isStart:
        iter = startIter
        discard iter.forwardChars(replen.cint)
        buffer.delete(startIter, iter)
        buffer.insert(startIter, sub, subLen)
      buffer.getStartIter(startIter)
      buffer.getEndIter(endIter) # endIter is invalid after delete/insert
      buffer.signalHandlerUnblock(buffer.handlerID)
    buffer.removeSourceMarks(startIter, endIter, UseCat)
    win.searchcountlabel.text = ""
    entry.text = ""
  else: # set marks
    var occurences: int
    buffer.getIterAtMark(iter, buffer.insert)
    if iter.insideWord:
      let text = buffer.text(startIter, endIter, includeHiddenChars = true)
      let filepath: string = $view.buffer.path
      let dirtypath = saveDirty(filepath, text)
      free(text)
      if dirtyPath.isNil: return
      var line = newStringOfCap(240)
      let socket = newSocket()
      socket.connect("localhost", NSPort)
      ln = iter.line + 1
      cn = iter.lineIndex + 1
      socket.send("use " & filepath & ";" & dirtypath & ":" & $ln & ":" & $cn & "\c\L")
      var com, sk, sym, sig, path, lin, col, doc, percent: string
      while true:
        socket.readLine(line)
        if line.len == 0: break
        if line.find('\t') < 0: continue
        inc(occurences)
        (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
        if pathcheck.isNil: pathcheck = path
        if pathcheck != path: multiMod = true
        cn = parseInt(col)
        ln = parseInt(lin) - 1
        let h = sym.split('.')[^1]
        if fix.isNil: fix = h else: assert fix == h
        buffer.getIterAtLineIndex320(startIter, ln.cint, cn.cint)
        endIter = startIter
        discard endIter.forwardChars(fix.len.cint)
        buffer.applyTag(tag, startIter, endIter)
        discard buffer.createSourceMark(NullStr, UseCat, startIter)
      socket.close
      dirtypath.removeFile
    win.searchcountlabel.text = "Usage: " & $occurences
    if rep and occurences > 0: # we intent to replace, so prepair for that
      replen = fix.len
      if entry.textLength == 0:
        entry.text = fix
        showMsg(win, "Caution: Replacement text was empty!")
      else:
        view.searchSettings.setSearchText(entry.getText)
        while gtk3.eventsPending(): discard gtk3.mainIteration()
        ln = view.searchContext.getOccurrencesCount
        if ln > 0:
          showMsg(win, "Caution: Replacement exits in file! ($1 times)" % [$ln])
        view.searchSettings.setSearchText("")
      if multiMod: showMsg(win, "Caution: Symbol is used in other modules")
    else:
      replen = -1
      if rep and occurences == 0:
        showMsg(win, "Nothing selected for substitition!")

proc use(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  useorrep(action, parameter, app, false)

proc userep(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  useorrep(action, parameter, app, true)

proc check(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  var ln, cn: int
  var startIter, endIter, iter: TextIterObj
  let windows: GList = application(app).windows
  if windows.isNil: return
  let win: NimEdAppWindow = nimEdAppWindow(windows.data)
  var view: NimView = nimEdApp(app).lastActiveView
  view.freeErrors
  let buffer: gtksource.Buffer = gtksource.buffer(view.getBuffer)
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  buffer.removeTagByName(ErrorTagName, startIter, endIter)
  for i in 0 .. MaxErrorTags:
    buffer.removeTagByName($i, startIter, endIter)
  buffer.removeSourceMarks(startIter, endIter, NullStr)
  let text = buffer.text(startIter, endIter, includeHiddenChars = true)
  let filepath: string = $view.buffer.path
  let filename = filepath.splitFile[1]
  let dirtypath = saveDirty(filepath, text)
  var line = newStringOfCap(240)
  var attrs = newMarkAttributes()
  var color = RGBAObj(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.2)
  attrs.background = color
  attrs.iconName = "list-remove"
  view.setMarkAttributes(ErrorTagName, attrs, priority = 1)
  objectUnref(attrs)
  let socket = newSocket()
  socket.connect("localhost", NSPort)
  socket.send("chk " & filepath & ";" & dirtypath & ":1:1\c\L")
  var errors = false
  var last: string
  while true:
    var isError, firstError, ignore: bool
    last = line
    socket.readLine(line)
    if line.len == 0: break
    if line == "\c\l" or line == last: continue
    if line.startsWith("Hint"): continue
    var errorPos = find(line, "Error", 12)
    if errorPos >= 0:
      ignore = not line.startsWith(filename)
      if not ignore:
        firstError = not errors
        errors = true
      isError = true
    else:
      isError = false
      errorPos = find(line, "Hint", 12)
      ignore = not line.startsWith(filename)
    if ignore: continue
    if errorPos >= 0:
      var i = skipUntil(line, '(') + 1
      var j = parseInt(line, ln, i)
      i = i + j + 2
      j = parseInt(line, cn, i)
      ln -= 1
      #cn -= 1
      if cn < 0: cn = 0 # may that really happen? and why
      if firstError:
        goto(view, ln, cn, true)
      line = substr(line, errorPos)
      let id = view.addError(line, ln, cn)
      if id > 0:
        buffer.getIterAtLineIndex320(startIter, ln.cint, cn.cint)
        iter = startIter
        if isError:
          if iter.line == 0:
            discard iter.backwardLine
          else:
            discard iter.backwardLine
            discard iter.forwardLine
          discard buffer.createSourceMark(NullStr, ErrorTagName, iter)
        let tag: TextTag = buffer.tagTable.lookup(ErrorTagName)
        assert(tag != nil)
        discard startiter.backwardChar
        if startIter.hasTag(tag):
          discard startIter.forwardToTagToggle(tag)
        discard startiter.forwardChar
        endIter = startIter
        iter = startIter
        discard iter.forwardToLineEnd
        discard endIter.forwardChar
        discard endIter.forwardFindChar(advanceErrorWord, userData = nil, limit = iter)
        buffer.applyTag(tag, startIter, endIter)
        buffer.applyTagByName($id, startIter, endIter)
    else:
      discard view.addError(line, ln, cn)
  socket.close
  view.showLinemarks = errors
  dirtypath.removeFile

var appEntries = [
  gio.GActionEntryObj(name: "preferences", activate: preferencesActivated, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "quit", activate: quitActivated, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "gotoDef", activate: gotoDef, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "con", activate: con, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "use", activate: use, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "userep", activate: userep, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "findNext", activate: findNext, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "findPrev", activate: findPrev, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "activateSearchEntry", activate: activateSearchEntry, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "gotoNextMark", activate: gotoNextMark, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "gotoPrevMark", activate: gotoPrevMark, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "find", activate: find, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "comp", activate: check, parameterType: nil, state: nil, changeState: nil)]

proc onFilechooserbutton1FileSet(widget: FileChooserButton, userData: GPointer) {.exportc, cdecl.} =
  var
    win: NimEdAppWindow = nimEdAppWindow(userData)
  let grid: Grid = win.grid
  let notebook: Notebook = notebook(grid.childAt(0, 1))
  let file: GFile = newFileForPath(filechooser(widget).filename)
  nimEdAppWindowSmartOpen(win, file)

const
  str0 = ".tooltip {background-color: rgba($1, $2, $3, 0.9); color: rgba($4, $5, $6, 1.0); \n}"

proc setTTColor(fg, bg: cstring) =
  var rgba_bg: gdk3.RGBAObj
  var rgba_fg: gdk3.RGBAObj
  if not rgbaParse(rgba_fg, bg): return
  if not rgbaParse(rgba_bg, fg): return
  let str: string = str0 % map([rgba_bg.red, rgba_bg.green, rgba_bg.blue, rgba_fg.red, rgba_fg.green, rgba_fg.blue], proc(x: cdouble): string = $system.int(x*255))
  var gerror: GError
  let provider: CssProvider = newCssProvider()
  let display: Display = displayGetDefault()
  let screen: gdk3.Screen = getDefaultScreen(display)
  styleContextAddProviderForScreen(screen, styleProvider(provider), STYLE_PROVIDER_PRIORITY_APPLICATION.cuint)
  discard loadFromData(provider, str, GSize(-1), gerror)
  if gerror != nil:
    discard # error(gerror.message)
  objectUnref(provider)

proc nimEdAppStartup(app: gio.GApplication) {.cdecl.} =
  var
    builder: Builder
    appMenu: gio.GMenuModel
    quitAccels = [cstring "<Ctrl>Q", nil]
    gotoDefAccels = [cstring "<Ctrl>W", nil]
    findAccels = [cstring "<Ctrl>F", nil]
    compAccels = [cstring "<Ctrl>E", nil]
    userepAccels = [cstring "<Ctrl>R", nil]
    useAccels = [cstring "<Ctrl>U", nil]
    conAccels = [cstring "<Ctrl>P", nil]
    activateSearchEntryAccels = [cstring "<Ctrl>slash", nil]
    findNextAccels = [cstring "<Ctrl>G", nil]
    findPrevAccels = [cstring "<Ctrl><Shift>G", nil]
    gotoNextMarkAccels = [cstring "<Ctrl>N", nil]
    gotoPrevMarkAccels = [cstring "<Ctrl><Shift>N", nil]
    my_user_data: int64  = 0xDEADBEE1
  # register the GObject types so builder can use them, see
  # https://mail.gnome.org/archives/gtk-list/2015-March/msg00016.html
  discard viewGetType()
  discard completionInfoGetType()
  discard styleSchemeChooserButtonGetType()
  gApplicationClass(nimEdAppParentClass).startup(app)
  addActionEntries(gio.gActionMap(app), addr appEntries[0], cint(len(appEntries)), app)
  setAccelsForAction(application(app), "app.quit", cast[cstringArray](addr quitAccels))
  setAccelsForAction(application(app), "app.gotoDef", cast[cstringArray](addr gotoDefAccels))
  setAccelsForAction(application(app), "app.con", cast[cstringArray](addr conAccels))
  setAccelsForAction(application(app), "app.use", cast[cstringArray](addr useAccels))
  setAccelsForAction(application(app), "app.userep", cast[cstringArray](addr userepAccels))
  setAccelsForAction(application(app), "app.findNext", cast[cstringArray](addr findNextAccels))
  setAccelsForAction(application(app), "app.findPrev", cast[cstringArray](addr findPrevAccels))
  setAccelsForAction(application(app), "app.activateSearchEntry", cast[cstringArray](addr activateSearchEntryAccels))
  setAccelsForAction(application(app), "app.gotoNextMark", cast[cstringArray](addr gotoNextMarkAccels))
  setAccelsForAction(application(app), "app.gotoPrevMark", cast[cstringArray](addr gotoPrevMarkAccels))
  setAccelsForAction(application(app), "app.find", cast[cstringArray](addr findAccels))
  setAccelsForAction(application(app), "app.comp", cast[cstringArray](addr compAccels))
  builder = newBuilder(resourcePath = "/org/gtk/ned/app-menu.ui")
  appMenu = gMenuModel(getObject(builder, "appmenu"))
  setAppMenu(application(app), appMenu)
  gtk3.connectSignals(builder, cast[GPointer](addr my_user_data))
  objectUnref(builder)

proc switchPage(notebook: Notebook; page: Widget; pageNum: cuint; userData: Gpointer) {.cdecl.} =
  let win = nimEdAppWindow(userData)
  win.statuslabel.text = ""

proc nimEdAppActivateOrOpen(win: NimEdAppWindow) =
  let notebook: Notebook = newNotebook()
  bindWithMapping(win.settings, "showtabs", notebook, "show-tabs", gio.GSettingsBindFlags.GET, getMappingTabs, nil, notebook, nil)
  discard gSignalConnect (notebook, "page-added", gCallback(pageNumChanged), win)
  discard gSignalConnect (notebook, "page-removed", gCallback(pageNumChanged), win)
  discard gSignalConnect (notebook, "switch-page", gCallback(switchPage), win)
  show(notebook)
  attach(win.grid, notebook, 0, 1, 1, 1)
  let scheme: cstring  = getString(win.settings, StyleSchemeSettingsID)
  let manager = styleSchemeManagerGetDefault()
  let style = getScheme(manager, scheme)
  var st: gtksource.Style = gtksource.getStyle(style, "text")
  if st != nil:
    var fg, bg: cstring
    objectGet(st, "foreground", addr fg, nil)
    objectGet(st, "background", addr bg, nil)
    setTTColor(fg, bg)
    free(fg)
    free(bg)
  st = gtksource.getStyle(style, "search-match")
  if st != nil:
    var fg, bg: cstring
    objectGet(st, "foreground", addr fg, nil)
    objectGet(st, "background", addr bg, nil)
    win.searchMatchBg = $bg
    win.searchMatchFg = $fg
    free(fg)
    free(bg)
  win.setDefaultSize(800, 500)
  present(win)

proc nimEdAppActivate(app: gio.GApplication) {.cdecl.} =
  let win = nimEdAppWindowNew(nimEdApp(app))
  nimEdAppActivateOrOpen(win)

proc nimEdAppOpen(app: gio.GApplication; files: gio.GFileArray; nFiles: cint; hint: cstring) {.cdecl.} =
  var
    windows: glib.GList
    win: NimEdAppWindow
  windows = getWindows(application(app))
  if windows.isNil:
    win = nimEdAppWindowNew(nimEdApp(app))
    nimEdAppActivateOrOpen(win)
  else:
    win = nimEdAppWindow(windows.data)
  win.logLevel = LogLevel.log
  win.statusID1 = win.statusbar.getContextID("StatudID1")
  win.statusID2 = win.statusbar.getContextID("StatudID2")
  let notebook: Notebook = gtk3.notebook(win.grid.childAt(0, 1))
  let nimBinPath = findExe("nim")
  doAssert(nimBinPath != nil, "we need nim executable!")
  let nimsuggestBinPath = findExe("nimsuggest")
  doAssert(nimsuggestBinPath != nil, "we need nimsuggest executable!")
  let nimPath = nimBinPath.splitFile.dir.parentDir
  nsProcess = startProcess(nimsuggestBinPath, nimPath,
                     ["--v2", "--threads:on", "--port:" & $NSPort, $files[0].path],
                     options = {poStdErrToStdOut, poUseShell})
  createThread[NimEdAppWindow](thread, showData, win)
  for i in 0 ..< nFiles:
    nimEdAppWindowSmartOpen(win, files[i])

proc nimEdAppClassInit(klass: NimEdAppClass) =
  klass.startup = nimEdAppStartup
  klass.activate = nimEdAppActivate
  klass.open = nimEdAppOpen

proc nimEdAppNew: NimEdApp {.cdecl.} =
  nimEdApp(newObject(typeNimEdApp, "application-id", "org.gtk.ned",
           "flags", gio.GApplicationFlags.HANDLES_OPEN, nil))

proc initapp {.cdecl.} =
  var
    cmdCount {.importc, global.}: cint
    cmdLine {.importc, global.}: cstringArray
  discard glib.setenv("GSETTINGS_SCHEMA_DIR", ".", false)
  discard run(nimEdAppNew(), cmdCount, cmdLine)

proc cleanup {.noconv.} =
  var msg: StatusMsg
  msg.filepath = nil
  channel.send(msg)
  joinThreads(thread)
  if nsProcess != nil:
    nsProcess.terminate
    discard nsProcess.waitForExit
    nsProcess.close

addQuitProc(cleanup)
#[ we use a text view for logging now
var L = newConsoleLogger()
L.levelThreshold = lvlAll
addHandler(L)
]#
initapp()

# 1783 lines
