
# pull in external modules
_ ?= require '../third_party/underscore-min.js'
util ?= require './util.js'
opcodes ?= require './opcodes'

# things assigned to root will be available outside this module
root = this 

class ExceptionHandler
  parse: (bytes_array,constant_pool) ->
    @start_pc   = util.read_uint(bytes_array.splice(0,2))
    @end_pc     = util.read_uint(bytes_array.splice(0,2))
    @handler_pc = util.read_uint(bytes_array.splice(0,2))
    cti = util.read_uint(bytes_array.splice(0,2))
    @catch_type = if cti==0 then "<all>" else constant_pool.get(cti).deref()
    return bytes_array

class Code
  parse: (bytes_array,constant_pool) ->
    @max_stack = util.read_uint(bytes_array.splice(0,2))
    @max_locals = util.read_uint(bytes_array.splice(0,2))
    @code_len = util.read_uint(bytes_array.splice(0,4))
    throw "Attribute._parse_code: Code length is zero" if @code_len == 0
    code_array = new util.BytesArray bytes_array.splice(0, @code_len)
    @opcodes = @parse_code code_array, constant_pool
    except_len = util.read_uint(bytes_array.splice(0,2))
    @exception_handlers = (new ExceptionHandler for _ in [0...except_len])
    for eh in @exception_handlers
      bytes_array = eh.parse(bytes_array,constant_pool)
    # yes, there are even attrs on attrs. BWOM... BWOM...
    [@attrs,bytes_array] = root.make_attributes(bytes_array,constant_pool)
    return bytes_array

  parse_code: (bytes_array, constant_pool) ->
    rv = {}
    while bytes_array.has_bytes()
      op_index = bytes_array.index
      c = bytes_array.get_uint(1)&0xFF
      op = opcodes[c]
      op.take_args(bytes_array, constant_pool)
      rv[op_index] = op
    return rv

  each_opcode: (fn) ->
    for i in [0..@code_len] when i of @opcodes
      fn(i, @opcodes[i])

class LineNumberTable extends Array
  parse: (bytes_array,constant_pool) ->
    lnt_len = util.read_uint(bytes_array.splice(0,2))
    for _ in [0...lnt_len]
      spc = util.read_uint(bytes_array.splice(0,2))
      ln = util.read_uint(bytes_array.splice(0,2))
      this.push {'start_pc': spc,'line_number': ln}
    return bytes_array

class SourceFile
  parse: (bytes_array,constant_pool) ->
    @name = constant_pool.get(util.read_uint(bytes_array.splice(0,2))).value
    return bytes_array

class StackMapTable
  # this is a dud class. Merely used to consume the correct number of input bytes.
  parse: (bytes_array, constant_pool) ->
    @name_ref = util.read_uint(bytes_array.splice(0, 2))
    @length = util.read_uint(bytes_array.splice(0, 4))
    @num_entries = util.read_uint(bytes_array.splice(0, 2))
    @parse_entries bytes_array for i in [0..@num_entries]
    return bytes_array

  parse_entries: (bytes_array) ->
    frame_type = bytes_array.shift()
    switch frame_type
      when 0 <= frame_type < 64
        break # same_frame
      when 64 <= frame_type < 128
        @parse_verification_type_info bytes_array
      when 247
        bytes_array.splice(0, 2)
        @parse_verification_type_info bytes_array
      when 248 <= frame_type < 251
        bytes_array.splice(0, 2)
      when 251
        bytes_array.splice(0, 2)
      when 252 <= frame_type < 255
        bytes_array.splice(0, 2)
        @parse_verification_type_info bytes_array for i in [0...frame_type-251]
      when 255
        bytes_array.splice(0, 2)
        num_locals = bytes_array.splice(0, 2)
        @parse_verification_type_info bytes_array for i in [0...num_locals]
        num_stack_items = bytes_array.splice(0, 2)
        @parse_verification_type_info bytes_array for i in [0...num_stack_items]

  parse_verification_type_info: (bytes_array) ->
    tag = bytes_array.shift()
    bytes_array.splice(0, 2) if tag == 7

root.make_attributes = (bytes_array,constant_pool) ->
  #TODO: add classes for additional attr types
  attr_types = {
    'Code': Code, 'LineNumberTable': LineNumberTable, 'SourceFile': SourceFile,
    'StackMapTable': StackMapTable
  }
  num_attrs = util.read_uint(bytes_array.splice(0,2))
  attrs = []
  for _ in [0...num_attrs]
    name = constant_pool.get(util.read_uint(bytes_array.splice(0,2))).value
    throw "Attribute.parse: Invalid constant_pool reference: '#{name}'" unless name
    attr_len = util.read_uint(bytes_array.splice(0,4))  # unused
    throw "NYI: attr_type #{name}" if not attr_types[name]?
    attr = new attr_types[name]
    bytes_array = attr.parse(bytes_array,constant_pool)
    attrs.push attr
  return [attrs,bytes_array]

module?.exports = root.make_attributes
