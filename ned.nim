# NEd (NimEd) -- a minimal GTK3/GtkSourceView Nim editor with nimsuggest support 
# S. Salewski, 2016-JUL-10
# v 0.1
{.deadCodeElim: on.}
{.link: "resources.o".}

import gobject, gtk3, gdk3, gio, glib, gtksource, gdk_pixbuf, pango
from parseutils import skipUntil, parseInt
import osproc, streams, os, net, strutils, sequtils, logging

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
  NSPort = Port(6000)
  StyleSchemeSettingsID = cstring("styleschemesettingsid") # must be lower case

var nsProcess: Process # nimsuggest

type
  NimEdAppWindow* = ptr NimEdAppWindowObj
  NimEdAppWindowObj* = object of gtk3.ApplicationWindowObj

  NimEdAppWindowClass = ptr NimEdAppWindowClassObj
  NimEdAppWindowClassObj = object of gtk3.ApplicationWindowClassObj

  NimEdAppWindowPrivate = ptr  NimEdAppWindowPrivateObj
  NimEdAppWindowPrivateObj = object
    grid: gtk3.Grid
    settings: gio.GSettings
    gears: MenuButton
    searchentry: SearchEntry
    savebutton: Button
    buffers: GList

gDefineTypeWithPrivate(NimEdAppWindow, applicationWindowGetType())

template typeNimEdAppWindow*(): expr = nimEdAppWindowGetType()

proc nimEdAppWindow*(obj: GPointer): NimEdAppWindow =
  gTypeCheckInstanceCast(obj, typeNimEdAppWindow, NimEdAppWindowObj)

proc isNimEdAppWindow*(obj: GPointer): GBoolean =
  gTypeCheckInstanceType(obj, typeNimEdAppWindow)

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

  NimViewPrivate = ptr NimViewPrivateObj
  NimViewPrivateObj = object

  NimViewClass = ptr NimViewClassObj
  NimViewClassObj = object of gtksource.ViewClassObj

gDefineType(NimView, viewGetType())

template typeNimView*(): expr = nimViewGetType()

proc nimView(obj: GPointer): NimView =
  gTypeCheckInstanceCast(obj, nimViewGetType(), NimViewObj)

proc isNimView*(obj: GPointer): GBoolean =
  gTypeCheckInstanceType(obj, typeNimView)

# this hack is from gedit 3.20
proc scrollToCursor(v: GPointer): GBoolean {.cdecl.} =
  let v = nimView(v)
  let buffer = gtksource.buffer(v.getBuffer) # caution: v.buffer is a cast!
  v.scrollToMark(buffer.insert, withinMargin = 0.25, useAlign = false, xalign = 0, yalign = 0)
  v.idleScroll = 0
  return G_SOURCE_REMOVE

proc nimViewDispose(obj: GObject) {.cdecl.} =
  gObjectClass(nimViewParentClass).dispose(obj)

proc nimViewFinalize(gobject: GObject) {.cdecl.}

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
  let i = v.errors.length.int + 1
  if i > MaxErrorTags: return 0
  el = cast[ptr NimViewError](glib.malloc(sizeof(NimViewError)))
  el.gs = glib.newGString(s)
  el.line = line
  el.col = col
  el.id = i
  v.errors = glib.prepend(v.errors, el)
  return i

proc freeNVE(data: Gpointer) {.cdecl.} =
  let e = cast[ptr NimViewError](data)
  discard glib.free(e.gs, true)
  glib.free(data)

proc freeErrors(v: var NimView) {.cdecl.} =
  glib.freeFull(v.errors, freeNVE)
  v.errors = nil

proc nimViewFinalize(gobject: GObject) =
  var self = nimView(gobject)
  self.freeErrors
  gObjectClass(nimViewParentClass).finalize(gobject)

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
# ifaceOnit: The interface init function
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

template isProvider*(obj: expr): expr =
  gTypeCheckInstanceType(obj, typeProvider)

proc providerGetName(provider: CompletionProvider): cstring {.cdecl.} =
  dup(provider(provider).name)

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
    error(gerror.message)
    error("Can't create nimsuggest dirty file")
    return
  let h = gfile.path
  result = $h
  free(h)
  let res = gfile.replaceContents(text, len(text), etag = nil, makeBackup = false, GFileCreateFlags.PRIVATE, newEtag = nil, cancellable = nil, gerror)
  objectUnref(gfile)
  if not res:
    error(gerror.message)
    result = nil

type
  NimEdApp* = ptr NimEdAppObj
  NimEdAppObj = object of ApplicationObj
    lastActiveView: NimView

  NimEdAppClass = ptr NimEdAppClassObj
  NimEdAppClassObj = object of ApplicationClassObj

  NimEdAppPrivate = ptr NimEdAppPrivateObj
  NimEdAppPrivateObj = object

gDefineType(NimEdApp, gtk3.applicationGetType())

proc nimEdAppInit(self: NimEdApp) = discard

template typeNimEdApp*(): expr = nimEdAppGetType()

proc nimEdApp(obj: GPointer): NimEdApp =
  gTypeCheckInstanceCast(obj, nimEdAppGetType(), NimEdAppObj)

proc isNimEdApp*(obj: GPointer): GBoolean =
  gTypeCheckInstanceType(obj, typeNimEdApp)

# unused dummy proc
proc duper(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  echo "duper"

proc lastActiveViewFromWidget(w: Widget): NimView =
  nimEdApp(gtk3.window(w.toplevel).application).lastActiveView

proc onSearchentrySearchChanged(entry: SearchEntry; userData: GPointer) {.exportc, cdecl.} =
  let view: NimView = entry.lastActiveViewFromWidget
  view.searchSettings.setSearchText(entry.text)

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
      let buffer: gtksource.Buffer = gtksource.buffer(view.getBuffer)
      buffer.getStartIter(startIter)
      buffer.getEndIter(endIter)
      let text = buffer.text(startIter, endIter, includeHiddenChars = true)
      let filepath: string = $view.name
      let dirtypath = saveDirty(filepath, text)
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
  
proc save(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  var startIter, endIter: TextIterObj
  doAssert isNimEdAppWindow(app)
  let view: NimView = nimEdApp(nimEdAppWindow(app).getApplication).lastActiveView
  let buffer: gtksource.Buffer = gtksource.buffer(view.getBuffer)
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  let text = buffer.text(startIter, endIter, includeHiddenChars = true)
  var gerror: GError
  let gfile: GFile = newFileForPath(view.name) # never fails
  let res = gfile.replaceContents(text, len(text), etag = nil, makeBackup = false, GFileCreateFlags.NONE, newEtag = nil, cancellable = nil, gerror)
  objectUnref(gfile)
  if not res:
    error(gerror.message)

var winAppEntries = [
  gio.GActionEntryObj(name: "duper", activate: duper, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "save", activate: save, parameterType: nil, state: nil, changeState: nil)]

proc settingsChanged(settings: gio.GSettings; key: cstring; win: NimEdAppWindow) {.cdecl.} =
  let priv: NimEdAppWindowPrivate = nimEdAppWindowGetInstancePrivate(win)
  let manager = styleSchemeManagerGetDefault()
  let style = getScheme(manager, getString(settings, key))
  if style != nil:
    var p: GList = priv.buffers
    while p != nil:
      gtksource.buffer(p.data).setStyleScheme(style)
      p = p.next

# TODO: check
proc nimEdAppWindowInit(self: NimEdAppWindow) =
  var
    builder: Builder
    menu: gio.GMenuModel
    action: gio.GAction
  let priv: NimEdAppWindowPrivate = nimEdAppWindowGetInstancePrivate(self)
  initTemplate(self)
  priv.settings = newSettings("org.gtk.ned")
  discard gSignalConnect(priv.settings, "changed::styleschemesettingsid",
                   gCallback(settingsChanged), self)
  builder = newBuilder(resourcePath = "/org/gtk/ned/gears-menu.ui")
  menu = gMenuModel(getObject(builder, "menu"))
  setMenuModel(priv.gears, menu)
  objectUnref(builder)
  addActionEntries(gio.gActionMap(self), addr winAppEntries[0], cint(len(winAppEntries)), self)
  objectSet(settingsGetDefault(), "gtk-shell-shows-app-menu", true, nil)
  setShowMenubar(self, true)

proc nimEdAppWindowDispose(obj: GObject) {.cdecl.} =
  gObjectClass(nimEdAppWindowParentClass).dispose(obj)

proc nimEdAppWindowClassInit(klass: NimEdAppWindowClass) =
  klass.dispose = nimEdAppWindowDispose
  setTemplateFromResource(klass, "/org/gtk/ned/window.ui")
  widgetClassBindTemplateChildPrivate(klass, NimEdAppWindow, gears)
  widgetClassBindTemplateChildPrivate(klass, NimEdAppWindow, searchentry)
  widgetClassBindTemplateChildPrivate(klass, NimEdAppWindow, savebutton)
  widgetClassBindTemplateChildPrivate(klass, NimEdAppWindow, grid)

proc nimEdAppWindowNew*(app: NimEdApp): NimEdAppWindow =
  nimEdAppWindow(newObject(typeNimEdAppWindow, "application", app, nil))

type
  NedAppPrefs* = ptr NedAppPrefsObj
  NedAppPrefsObj = object of gtk3.DialogObj

  NedAppPrefsClass = ptr NedAppPrefsClassObj
  NedAppPrefsClassObj = object of gtk3.DialogClassObj

  NedAppPrefsPrivate = ptr NedAppPrefsPrivateObj
  NedAppPrefsPrivateObj = object
    settings: gio.GSettings
    font: gtk3.Widget
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

proc nedAppPrefsInit(self: NedAppPrefs) =
  let priv: NedAppPrefsPrivate = nedAppPrefsGetInstancePrivate(self)
  initTemplate(self)
  priv.settings = newSettings("org.gtk.ned")
  `bind`(priv.settings, "font", priv.font, "font", gio.GSettingsBindFlags.DEFAULT)
  discard gSignalConnect(priv.style, "notify::style-scheme", gCallback(styleSchemeChanged), priv.settings)

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
  widgetClassBindTemplateChildPrivate(klass, NedAppPrefs, style)

proc nedAppPrefsNew*(win: NimEdAppWindow): NedAppPrefs =
  nedAppPrefs(newObject(typeNedAppPrefs, "transient-for", win, "use-header-bar", true, nil))

proc preferencesActivated(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  let win: gtk3.Window = getActiveWindow(application(app))
  let prefs: NedAppPrefs = nedAppPrefsNew(nimEdAppWindow(win))
  present(prefs)

proc closeTab(button: Button; userData: GPointer) {.cdecl.} =
  let win = nimEdAppWindow(button.toplevel)
  let priv: NimEdAppWindowPrivate = nimEdAppWindowGetInstancePrivate(win)
  let grid: Grid = priv.grid
  let notebook: Notebook = notebook(grid.childAt(0, 1))
  let i = cast[cint](userdata)
  if i >= 0:
    var b = nimView(scrolledWindow(notebook.nthPage(i)).child).getBuffer
    priv.buffers = priv.buffers.remove(b)
    notebook.removePage(i)

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

proc onBufferModified(textBuffer: TextBuffer; userData: GPointer) {.cdecl.} =
  var l: Label = label(userdata)
  var s: string = $l.text
  if textBuffer.modified:
    if s[0] != '*': s.insert("*")
  else:
    if s[0] == '*': s.delete(0, 0)
  l.text = s

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

proc onGrabFocus(widget: Widget; userData: GPointer) {.cdecl.} =
  nimEdApp(gtk3.window(widget.toplevel).application).lastActiveView = nimView(widget)

proc nimEdAppWindowOpen*(win: NimEdAppWindow; notebook: Notebook; file: gio.GFile; line: cint = 0; column: cint = 0) =
  var
    contents: cstring
    buffer: gtksource.Buffer
    length: Gsize
    error: GError
    startIter, endIter: TextIterObj
  let priv: NimEdAppWindowPrivate = nimEdAppWindowGetInstancePrivate(win)
  let basename = file.basename
  var view: NimView = notebook.setVisibleViewName(file.path)
  if view.isNil:
    let scrolled: ScrolledWindow = newScrolledWindow(nil, nil)
    scrolled.hexpand = true
    scrolled.vexpand = true
    let language: gtksource.Language = languageManagerGetDefault().guessLanguage(basename, nil)
    if language.isNil:
      buffer = gtksource.newBuffer(table = nil)
    else:
      buffer = gtksource.newBuffer(language)
    priv.buffers = glib.prepend(priv.buffers, buffer)
    view = newNimView(buffer)
    if nimEdApp(gtk3.window(win.toplevel).application).lastActiveView.isNil:
      nimEdApp(gtk3.window(win.toplevel).application).lastActiveView = view
    discard buffer.createTag(ErrorTagName, "underline", pango.Underline.Error, nil)
    for i in 0 .. MaxErrorTags:
      discard buffer.createTag($i, nil)
    view.name = file.path
    view.hasTooltip = true
    discard gSignalConnect(view, "query-tooltip", gCallback(showErrorTooltip), nil)
    discard gSignalConnect(view, "grab_focus", gCallback(onGrabFocus), nil)
    let completion: Completion = getCompletion(view)
    initCompletion(view, completion, win)
    view.editable = true
    view.cursorVisible = true
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
    discard gSignalConnect(closeButton, "clicked", gCallback(closeTab), cast[GPointer](notebook.nPages))
    let label = newLabel(basename)
    label.ellipsize = pango.EllipsizeMode.END
    label.halign = Align.START
    label.valign = Align.CENTER
    discard gSignalConnect(buffer, "modified-changed", gCallback(onBufferModified), label)
    let box = newBox(Orientation.HORIZONTAL, spacing = 0)
    box.packStart(label, expand = true, fill = false, padding = 0)
    box.packStart(closeButton, expand = false, fill = false, padding = 0)
    box.showAll
    let pageNum = notebook.appendPage(scrolled, box)
    notebook.currentPage = pageNum
    notebook.childSet(scrolled, "tab-expand", true, nil)
    if loadContents(file, nil, contents, length, nil, error):
      buffer.setText(contents, length.cint)
      free(contents)
    let tag: gtk3.TextTag = buffer.createTag(nil, nil)
    `bind`(priv.settings, "font", tag, "font", gio.GSettingsBindFlags.DEFAULT)
    let scheme: cstring  = getString(priv.settings, StyleSchemeSettingsID)
    if scheme != nil:
      let manager = styleSchemeManagerGetDefault()
      let style = getScheme(manager, scheme)
      if style != nil:
        buffer.setStyleScheme(style)
    buffer.getStartIter(startIter)
    buffer.getEndIter(endIter)
    buffer.applyTag(tag, startIter, endIter)
    buffer.modified = false
    free(basename)
  else:
    buffer = gtksource.buffer(view.getBuffer)
  if line > 1:
    buffer.getIterAtLineIndex(startIter, line - 1, column - 1)
    buffer.placeCursor(startIter)
    if view.idleScroll == 0:
      view.idleScroll = idleAdd(GSourceFunc(scrollToCursor), view)
    markLocation(view, line - 1, column - 1)
  view.searchSettings = newSearchSettings()
  view.searchContext = newSearchContext(buffer, view.searchSettings)

proc quitActivated(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  quit(gApplication(app))

proc find(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  var startIter, endIter: TextIterObj
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

proc gotoDef(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  var startIter, endIter, iter: TextIterObj
  let windows: GList = application(app).windows
  if windows.isNil: return
  let win: NimEdAppWindow = nimEdAppWindow(windows.data)
  let priv: NimEdAppWindowPrivate = nimEdAppWindowGetInstancePrivate(win)
  let view: NimView = nimEdApp(app).lastActiveView
  let buffer: gtksource.Buffer = gtksource.buffer(view.getBuffer)
  buffer.getStartIter(startIter)
  buffer.getEndIter(endIter)
  let text = buffer.text(startIter, endIter, includeHiddenChars = true)
  let filepath: string = $view.name
  let dirtypath = saveDirty(filepath, text)
  if dirtyPath.isNil: return
  var line = newStringOfCap(240)
  let socket = newSocket()
  socket.connect("localhost", NSPort)
  buffer.getIterAtMark(iter, buffer.insert)
  let ln = iter.line + 1
  let column = iter.lineIndex + 1
  socket.send("def " & filepath & ";" & dirtypath & ":" & $ln & ":" & $column & "\c\L")
  var com, sk, sym, sig, path, lin, col, doc, percent: string
  while true:
    socket.readLine(line)
    if line.len == 0: break
    if line == "\c\l": continue
    (com, sk, sym, sig, path, lin, col, doc, percent) = line.split('\t')
  socket.close
  dirtypath.removeFile
  let grid: Grid = priv.grid
  let notebook: Notebook = notebook(grid.childAt(0, 1))
  let file: GFile = newFileForPath(path)
  nimEdAppWindowOpen(win, notebook, file, strutils.parseInt(lin).cint, strutils.parseInt(col).cint)

proc check(action: gio.GSimpleAction; parameter: glib.GVariant; app: Gpointer) {.cdecl.} =
  var ln, cn: int
  var startIter, endIter, iter: TextIterObj
  let windows: GList = application(app).windows
  if windows.isNil: return
  let win: NimEdAppWindow = nimEdAppWindow(windows.data)
  let priv: NimEdAppWindowPrivate = nimEdAppWindowGetInstancePrivate(win)
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
  let filepath: string = $view.name
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
    var isError, ignore: bool
    last = line
    socket.readLine(line)
    if line.len == 0: break
    if line == "\c\l" or line == last: continue
    if line.startsWith("Hint"): continue
    var errorPos = find(line, "Error", 12)
    if errorPos >= 0:
      ignore = not line.startsWith(filename)
      if not ignore: errors = true
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
      cn -= 1
      if cn < 0: cn = 0 # may that really happen? and why
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
  gio.GActionEntryObj(name: "find", activate: find, parameterType: nil, state: nil, changeState: nil),
  gio.GActionEntryObj(name: "comp", activate: check, parameterType: nil, state: nil, changeState: nil)]

proc onFilechooserbutton1FileSet(widget: FileChooserButton, userData: GPointer) {.exportc, cdecl.} =
  var
    win: NimEdAppWindow = nimEdAppWindow(userData)
  let priv: NimEdAppWindowPrivate = nimEdAppWindowGetInstancePrivate(win)
  let grid: Grid = priv.grid
  let notebook: Notebook = notebook(grid.childAt(0, 1))
  let file: GFile = newFileForPath(filechooser(widget).filename)
  nimEdAppWindowOpen(win, notebook, file)

const
  str0 = ".tooltip {background-color: rgba($1, $2, $3, 0.9); color: rgba($4, $5, $6, 1.0); \n}"

proc setTTColor(fg, bg: cstring) =
  var rgba_bg: gdk3.RGBAObj
  var rgba_fg: gdk3.RGBAObj
  if not rgbaParse(rgba_fg, bg): return
  if not rgbaParse(rgba_bg, fg): return
  let str: string = str0 % map([rgba_bg.red, rgba_bg.green, rgba_bg.blue, rgba_fg.red, rgba_fg.green, rgba_fg.blue], proc(x: cdouble): string = $(x*255).int)
  var gerror: GError
  let provider: CssProvider = newCssProvider()
  let display: Display = displayGetDefault()
  let screen: gdk3.Screen = getDefaultScreen(display)
  styleContextAddProviderForScreen(screen, styleProvider(provider), STYLE_PROVIDER_PRIORITY_APPLICATION.cuint)
  discard loadFromData(provider, str, GSize(-1), gerror)
  if gerror != nil:
    error(gerror.message)
  objectUnref(provider)

proc nimEdAppStartup(app: gio.GApplication) {.cdecl.} =
  var
    builder: Builder
    appMenu: gio.GMenuModel
    quitAccels = [cstring "<Ctrl>Q", nil]
    gotoDefAccels = [cstring "<Ctrl>D", nil]
    findAccels = [cstring "<Ctrl>F", nil]
    compAccels = [cstring "<Ctrl>E", nil]
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
  setAccelsForAction(application(app), "app.find", cast[cstringArray](addr findAccels))
  setAccelsForAction(application(app), "app.comp", cast[cstringArray](addr compAccels))
  builder = newBuilder(resourcePath = "/org/gtk/ned/app-menu.ui")
  appMenu = gMenuModel(getObject(builder, "appmenu"))
  setAppMenu(application(app), appMenu)
  gtk3.connectSignals(builder, cast[GPointer](addr my_user_data))
  objectUnref(builder)

proc nimEdAppActivateOrOpen(win: NimEdAppWindow) =
  let priv: NimEdAppWindowPrivate = nimEdAppWindowGetInstancePrivate(win)
  let notebook: Notebook = newNotebook()
  show(notebook)
  attach(priv.grid, notebook, 0, 1, 1, 1)
  let scheme: cstring  = getString(priv.settings, StyleSchemeSettingsID)
  if scheme != nil:
    let manager = styleSchemeManagerGetDefault()
    let style = getScheme(manager, scheme)
    if style != nil:
      let st: gtksource.Style = gtksource.getStyle(style, "text")
      if st != nil:
        var fg, bg: cstring
        objectGet(st, "foreground", addr fg, nil)
        objectGet(st, "background", addr bg, nil)
        setTTColor(fg, bg)
        free(fg)
        free(bg)
  win.setDefaultSize(600, 400)
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
  let priv: NimEdAppWindowPrivate = nimEdAppWindowGetInstancePrivate(win)
  let notebook: Notebook = gtk3.notebook(priv.grid.childAt(0, 1))
  let nimBinPath = findExe("nim")
  doAssert(nimBinPath != nil, "we need nim executable!")
  let nimsuggestBinPath = findExe("nimsuggest")
  doAssert(nimsuggestBinPath != nil, "we need nimsuggest executable!")
  let nimPath = nimBinPath.splitFile.dir.parentDir
  nsProcess = startProcess(nimsuggestBinPath, nimPath,
                     ["--v2", "--port:" & $NSPort, $files[0].path],
                     options = {poStdErrToStdOut, poUseShell})
  for i in 0 ..< nFiles:
    nimEdAppWindowOpen(win, notebook, files[i])

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
  if nsProcess != nil:
    nsProcess.terminate
    discard nsProcess.waitForExit
    nsProcess.close

addQuitProc(cleanup)
var L = newConsoleLogger()
L.levelThreshold = lvlAll
addHandler(L)

initapp()
