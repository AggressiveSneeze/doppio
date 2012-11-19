# Things assigned to root will be available outside this module.
root = exports ? window.runtime ?= {}

_ = require '../vendor/_.js'
gLong = require '../vendor/gLong.js'
util = require './util'
types = require './types'
ClassFile = require './ClassFile'
{log,vtrace,trace,debug,error} = require './logging'
{java_throw,YieldException} = require './exceptions'
{JavaObject,JavaClassObject,JavaArray,thread_name} = require './java_object'
{c2t} = types

"use strict"

class root.CallStack
  constructor: (initial_stack) ->
    @_cs = [new root.StackFrame null,[],[]]
    if initial_stack?
      @_cs[0].stack = initial_stack
    @resuming_stack = null

  length: -> @_cs.length
  push: (sf) -> @_cs.push sf
  pop: -> @_cs.pop()

  curr_frame: ->
    if @resuming_stack? then @_cs[@resuming_stack]
    else _.last(@_cs)

  get_caller: (frames_to_skip) -> @_cs[@_cs.length-1-frames_to_skip]

class root.StackFrame
  constructor: (@method,@locals,@stack) ->
    @pc = 0

# Contains all the mutable state of the Java program.
class root.RuntimeState
  constructor: (@print, @async_input, @read_classfile) ->
    # dict of field values of loaded and initialized classes
    @class_fields = Object.create null
    # dict of java.lang.Class objects (which are interned)
    @jclass_obj_pool = Object.create null
    # dict of ClassFiles that have been loaded
    @loaded_classes = Object.create null

    @high_oref = 1
    @string_pool = {}
    @lock_refs = {}  # map from monitor -> thread object
    @lock_counts = {}  # map from monitor -> count
    @waiting_threads = {}  # map from monitor -> list of waiting thread objects
    @thread_pool = []
    # initialize thread objects
    @curr_thread = {$meta_stack: new root.CallStack()}
    @push (group = @init_object 'java/lang/ThreadGroup')
    @method_lookup({class: 'java/lang/ThreadGroup', sig: '<init>()V'}).run(this)

    ct = @init_object 'java/lang/Thread',
      name: @init_carr 'main'
      priority: 1
      group: group
      threadLocals: null
    ct.$meta_stack = @meta_stack()
    @curr_thread = ct
    @curr_thread.$isAlive = true
    @thread_pool.push @curr_thread

  meta_stack: -> @curr_thread.$meta_stack

  # Init the first class, and put the command-line args on the stack for use by
  # its main method.
  initialize: (class_name, initial_args) ->
    unless @system_initialized?
      # initialize the system class
      @class_lookup(c2t 'java/lang/System').methods['initializeSystemClass()V'].run(this)
      @system_initialized = true
      debug "### finished system class initialization ###"

    # load the main class (which calls <clinit>, if needed)
    @class_lookup c2t class_name

    # prepare the call stack for main(String[] args)
    args = new JavaArray c2t('[Ljava/lang/String;'), @, (@init_string(a) for a in initial_args)
    @curr_thread.$meta_stack = new root.CallStack [args]
    debug "### finished runtime state initialization ###"

  show_state: () ->
    cf = @curr_frame()
    if cf?
      s = ((if x?.ref? then x.ref else x) for x in cf.stack)
      l = ((if x?.ref? then x.ref else x) for x in cf.locals)
      debug "showing current state: method '#{cf.method?.name}', stack: [#{s}], locals: [#{l}]"
    else
      debug "current frame is undefined. meta_stack: #{@meta_stack()}"

  wait: (monitor, yieldee) ->
    # add current thread to wait queue
    if @waiting_threads[monitor]?
      @waiting_threads[monitor].push @curr_thread
    else
      @waiting_threads[monitor] = [@curr_thread]
    # yield execution, to the locking thread if possible
    unless yieldee?
      yieldee = @lock_refs[monitor]
    @yield yieldee

  yield: (yieldee) ->
    unless yieldee?
      yieldee = (y for y in @thread_pool when y isnt @curr_thread).pop()
      unless yieldee?
        java_throw @, 'java/lang/Error', "tried to yield when no other thread was available"
    debug "TE: yielding #{thread_name @, @curr_thread} to #{thread_name @, yieldee}"
    my_thread = @curr_thread
    @curr_frame().resume = -> @curr_thread = my_thread
    rs = this
    throw new YieldException (cb) ->
      my_thread.$resume = cb
      rs.curr_thread = yieldee
      debug "TE: about to resume #{thread_name @, yieldee}"
      yieldee.$resume()

  curr_frame: -> @meta_stack().curr_frame()

  cl: (idx) -> @curr_frame().locals[idx]
  put_cl: (idx,val) -> @curr_frame().locals[idx] = val
  # Category 2 values (longs, doubles) take two slots in Java. Since we only
  # need one slot to represent a double in JS, we pad it with a null.
  put_cl2: (idx,val) -> @put_cl(idx,val); @put_cl(idx+1,null)

  push: (arg) -> @curr_frame().stack.push(arg)
  push2: (arg1, arg2) -> @curr_frame().stack.push(arg1, arg2)
  push_array: (args) ->
    cs = @curr_frame().stack
    Array::push.apply(cs, args)
  pop: () -> @curr_frame().stack.pop()
  pop2: () -> @pop(); @pop() # For category 2 values.

  # Program counter manipulation.
  curr_pc: ()   -> @curr_frame().pc
  goto_pc: (pc) -> @curr_frame().pc = pc
  inc_pc:  (n)  -> @curr_frame().pc += n

  # Heap manipulation.
  check_null: (obj) ->
    java_throw @, 'java/lang/NullPointerException', '' unless obj?
    obj
  set_obj: (type, obj={}) ->
    if type instanceof types.ArrayType
      new JavaArray type, @, obj
    else
      new JavaObject type, @, obj

  heap_newarray: (type,len) ->
    if len < 0
      java_throw @, 'java/lang/NegativeArraySizeException', "Tried to init [#{type} array with length #{len}"
    if type == 'J'
      new JavaArray c2t("[J"), @, (gLong.ZERO for i in [0...len] by 1)
    else if type[0] == 'L'  # array of object
      new JavaArray c2t("[#{type}"), @, (null for i in [0...len] by 1)
    else  # numeric array
      new JavaArray c2t("[#{type}"), @, (0 for i in [0...len] by 1)

  heap_put: (field_spec) ->
    val = if field_spec.type in ['J','D'] then @pop2() else @pop()
    obj = @pop()
    field = @field_lookup(field_spec)
    obj.set_field @, field_spec.name, val, field.class_type.toClassString()

  heap_get: (field_spec, obj) ->
    field = @field_lookup(field_spec)
    val = obj.get_field @, field_spec.name, field.class_type.toClassString()
    @push val
    @push null if field_spec.type in ['J','D']

  # static stuff
  static_get: (field_spec) ->
    f = @field_lookup(field_spec)
    @class_fields[f.class_type.toClassString()][f.name] ?= util.initial_value f.raw_descriptor

  static_put: (field_spec) ->
    val = if field_spec.type in ['J','D'] then @pop2() else @pop()
    f = @field_lookup(field_spec)
    @class_fields[f.class_type.toClassString()][f.name] = val

  # heap object initialization
  init_object: (cls, obj) ->
    type = c2t(cls)
    @class_lookup type
    @set_obj type, obj
  init_string: (str,intern=false) ->
    # this is a bit of a kludge: if the string we want to intern is __proto__ or a function name,
    # we fail to intern it.
    return @string_pool[str] if intern and @string_pool[str]?.type?.toClassString?() is 'java/lang/String'
    carr = @init_carr str
    jvm_str = new JavaObject c2t('java/lang/String'), @, {'value':carr, 'count':str.length}
    @string_pool[str] = jvm_str if intern
    return jvm_str
  init_carr: (str) ->
    new JavaArray c2t('[C'), @, (str.charCodeAt(i) for i in [0...str.length] by 1)

  # Returns a java.lang.Class object for JVM bytecode to do reflective stuff.
  # Loads the underlying class, but does not initialize it (and therefore does
  # not ensure that its ancestors and interfaces are present.)
  jclass_obj: (type, dyn=false, file=null) ->
    unless @jclass_obj_pool[type] isnt undefined
      file ?= @load_class type, dyn
      @jclass_obj_pool[type] = new JavaClassObject @, type, file
    @jclass_obj_pool[type]

  # Returns a ClassFile object. Loads the underlying class, but does not
  # initialize it.
  # We're technically supposed to load all the classes referenced in a constant
  # pool when loading a class, but it's probably not such a great idea to pull
  # in all those dependencies over the web. So we do both reflective and
  # 'static' class loading lazily. Still, there is a distinction between
  # constant-pool-loaded classes and reflection-loaded ones: load failures in
  # the former are Errors but merely Exceptions in the latter.  The `dyn`
  # parameter indicates this.
  load_class: (type, dyn) ->
    unless @loaded_classes[type]?
      if type instanceof types.ArrayType
        @loaded_classes[type] = ClassFile.for_array_type type
      else if type instanceof types.PrimitiveType
        @loaded_classes[type] = '<primitive>'
      else
        cls = type.toClassString()
        class_file = @read_classfile cls
        unless class_file?
          if dyn
            java_throw @, 'java/lang/ClassNotFoundException', cls
          else
            java_throw @, 'java/lang/NoClassDefFoundError', cls
        @loaded_classes[type] = class_file
    @loaded_classes[type]

  # Loads and initializes :type, and returns a ClassFile object. Should only be
  # called _immediately_ before a method invocation or field access. See section
  # 5.5 of the SE7 spec.
  class_lookup: (type, dyn) ->
    UNSAFE? || throw new Error "class_lookup needs a type object, got #{typeof type}: #{type}" unless type instanceof types.Type
    cls = type.toClassString?() ? type.toString()
    unless @class_fields[cls]?
      trace "loading new class: #{cls}"
      class_file = @load_class type, dyn
      @class_fields[cls] = Object.create null
      if type instanceof types.ArrayType
        component = type.component_type
        if component instanceof types.ArrayType or component instanceof types.ClassType
          @class_lookup component, dyn
      else if type instanceof types.ClassType
        @class_fields[cls] = c = Object.create null
        # Run class initialization code. Superclasses get init'ed first.  We
        # don't want to call this more than once per class, so don't do dynamic
        # lookup. See spec [2.17.4][1].
        # [1]: http://docs.oracle.com/javase/specs/jvms/se5.0/html/Concepts.doc.html#19075
        if class_file.super_class
          @class_lookup class_file.super_class, dyn

        # flag to let us know if we need to resume into <clinit> after a yield
        c.$in_progress = true
        class_file.methods['<clinit>()V']?.run(this)
        delete c.$in_progress  # no need to keep this around
    else if @meta_stack().resuming_stack?
      class_file = @load_class type, dyn
      c = @class_fields[cls]
      if class_file.super_class
        @class_lookup class_file.super_class, dyn
      if c.$in_progress?  # need to resume <clinit>
        trace "resuming an $in_progress class initialization"
        delete c.$in_progress
        class_file.methods['<clinit>()V']?.run(this)
    @load_class type, dyn
  create_dyn_class: (cls, data) ->
    # replicates some logic from class_lookup
    class_file = new ClassFile(data)
    @class_fields[cls] = Object.create null
    if class_file.super_class
      @class_lookup class_file.super_class
    type = c2t(util.int_classname cls)
    @loaded_classes[type] = class_file
    @jclass_obj type, true, class_file

  method_lookup: (method_spec) ->
    type = c2t method_spec.class
    cls = @class_lookup(type)
    method = cls.method_lookup(this, method_spec)
    return method if method?
    java_throw @, 'java/lang/NoSuchMethodError',
      "No such method found in #{method_spec.class}: #{method_spec.sig}"

  field_lookup: (field_spec) ->
    cls = @class_lookup c2t field_spec.class
    field = cls.field_lookup this, field_spec
    return field if field?
    java_throw @, 'java/lang/NoSuchFieldError',
      "No such field found in #{field_spec.class}: #{field_spec.name}"

  get_field_from_offset: (cls, offset) ->
    classname = cls.this_class.toClassString()
    until cls.fields[offset]?
      unless cls.super_class?
        java_throw @, 'java/lang/NullPointerException', "field #{offset} doesn't exist in class #{classname}"
      cls = @class_lookup(cls.super_class)
    cls.fields[offset]
