require 'mongo/util/byte_buffer'
require 'mongo/util/ordered_hash'
require 'mongo/objectid'

# See http://github.com/10gen/mongo/tree/master/db/jsobj.h

class BSON

  MINKEY = -1
  EOO = 0
  NUMBER = 1
  STRING = 2
  OBJECT = 3
  ARRAY = 4
  BINARY = 5
  UNDEFINED = 6
  OID = 7
  BOOLEAN = 8
  DATE = 9
  NULL = 10
  REGEX = 11
  REF = 12
  CODE = 13
  SYMBOL = 14
  CODE_W_SCOPE = 15
  NUMBER_INT = 16
  MAXKEY = 127

  def self.serialize_cstr(buf, val)
    buf.put_array(val.to_s.unpack("C*") + [0])
  end

  def initialize
    @buf = ByteBuffer.new
  end

  def to_a
    @buf.to_a
  end

  def serialize(obj)
    raise "Document is null" unless obj

    @buf.rewind
    # put in a placeholder for the total size
    @buf.put_int(0)

    obj.each {|k, v|
      type = bson_type(v, k)
      case type
      when STRING, CODE
        serialize_string_element(@buf, k, v, type)
      when NUMBER, NUMBER_INT
        serialize_number_element(@buf, k, v, type)
      when OBJECT
        serialize_object_element(@buf, k, v)
      when OID
        serialize_oid_element(@buf, k, v)
      when ARRAY
        serialize_array_element(@buf, k, v)
      when REGEX
        serialize_regex_element(@buf, k, v)
      when BOOLEAN
        serialize_boolean_element(@buf, k, v)
      when DATE
        serialize_date_element(@buf, k, v)
      when NULL
        serialize_null_element(@buf, k)
      when BINARY, UNDEFINED, REF, SYMBOL, CODE_W_SCOPE
        raise "unimplemented type #{type}"
      else
        raise "unhandled type #{type}"
      end
    }
    serialize_eoo_element(@buf)
    @buf.put_int(@buf.size, 0)
    self
  end

  def deserialize(buf=nil)
    # If buf is nil, use @buf, assumed to contain already-serialized BSON.
    # This is only true during testing.
    @buf = ByteBuffer.new(buf.to_a) if buf
    @buf.rewind
    @buf.get_int                # eat message size
    doc = {}
    while @buf.more?
      type = @buf.get
      case type
      when STRING, CODE
        key = deserialize_element_name(@buf)
        doc[key] = deserialize_string_data(@buf)
      when NUMBER
        key = deserialize_element_name(@buf)
        doc[key] = deserialize_number_data(@buf)
      when NUMBER_INT
        key = deserialize_element_name(@buf)
        doc[key] = deserialize_number_int_data(@buf)
      when OID
        key = deserialize_element_name(@buf)
        doc[key] = deserialize_oid_data(@buf)
      when ARRAY
        key = deserialize_element_name(@buf)
        doc[key] = deserialize_array_data(@buf)
      when REGEX
        key = deserialize_element_name(@buf)
        doc[key] = deserialize_regex_data(@buf)
      when OBJECT
        key = deserialize_element_name(@buf)
        doc[key] = deserialize_object_data(@buf)
      when BOOLEAN
        key = deserialize_element_name(@buf)
        doc[key] = deserialize_boolean_data(@buf)
      when DATE
        key = deserialize_element_name(@buf)
        doc[key] = deserialize_date_data(@buf)
      when NULL
        key = deserialize_element_name(@buf)
        doc[key] = nil
      when EOO
        break
      else
        raise "Unknown type #{type}, key = #{key}"
      end
    end
    @buf.rewind
    doc
  end

  def hex_dump
    str = ''
    @buf.to_a.each_with_index { |b,i|
      if (i % 8) == 0
        str << "\n" if i > 0
        str << '%4d:  ' % i
      else
        str << ' '
      end
      str << '%02X' % b
    }
    str
  end

  def deserialize_date_data(buf)
    Time.at(buf.get_long)
  end

  def deserialize_boolean_data(buf)
    buf.get == 1
  end

  def deserialize_number_data(buf)
    buf.get_double
  end

  def deserialize_number_int_data(buf)
    buf.get_int
  end

  def deserialize_object_data(buf)
    size = buf.get_int
    buf.position -= 4
    BSON.new.deserialize(buf.get(size))
  end

  def deserialize_array_data(buf)
    h = deserialize_object_data(buf)
    a = []
    h.each { |k, v| a[k.to_i] = v }
    a
  end

  def deserialize_regex_data(buf)
    str = deserialize_element_name(buf)
    options_str = deserialize_element_name(buf)
    options = 0
    options |= Regexp::IGNORECASE if options_str.include?('i')
    options |= Regexp::MULTILINE if options_str.include?('m')
    options |= Regexp::EXTENDED if options_str.include?('x')
    Regexp.new(str, options)
  end

  def deserialize_string_data(buf)
    len = buf.get_int
    bytes = buf.get(len)
    bytes[0..-2].pack("C*")
  end

  def deserialize_oid_data(buf)
    XGen::Mongo::Driver::ObjectID.new(buf.get(12))
  end

  def serialize_eoo_element(buf)
    buf.put(EOO)
  end

  def serialize_null_element(buf, key)
    buf.put(NULL)
    self.class.serialize_cstr(buf, key)
  end

  def serialize_boolean_element(buf, key, val)
    buf.put(BOOLEAN)
    self.class.serialize_cstr(buf, key)
    buf.put(val ? 1 : 0)
  end

  def serialize_date_element(buf, key, val)
    buf.put(DATE)
    self.class.serialize_cstr(buf, key)
    buf.put_long(val.to_i)
  end

  def serialize_number_element(buf, key, val, type)
    buf.put(type)
    self.class.serialize_cstr(buf, key)
    if type == NUMBER
      buf.put_double(val)
    else
      buf.put_int(val)
    end
  end

  def serialize_object_element(buf, key, val, opcode=OBJECT)
    buf.put(opcode)
    self.class.serialize_cstr(buf, key)
    buf.put_array(BSON.new.serialize(val).to_a)
  end

  def serialize_array_element(buf, key, val)
    # Turn array into hash with integer indices as keys
    h = OrderedHash.new
    i = 0
    val.each { |v| h[i] = v; i += 1 }
    serialize_object_element(buf, key, h, ARRAY)
  end

  def serialize_regex_element(buf, key, val)
    buf.put(REGEX)
    self.class.serialize_cstr(buf, key)

    str = val.to_s.sub(/.*?:/, '')[0..-2] # Turn "(?xxx:yyy)" into "yyy"
    self.class.serialize_cstr(buf, str)

    options = val.options
    options_str = ''
    options_str << 'i' if ((options & Regexp::IGNORECASE) != 0)
    options_str << 'm' if ((options & Regexp::MULTILINE) != 0)
    options_str << 'x' if ((options & Regexp::EXTENDED) != 0)
    self.class.serialize_cstr(buf, options_str)
  end

  def serialize_oid_element(buf, key, val)
    buf.put(OID)
    self.class.serialize_cstr(buf, key)

    buf.put_array(val.to_a)
  end

  def serialize_string_element(buf, key, val, type)
    buf.put(type)
    self.class.serialize_cstr(buf, key)

    # Make a hole for the length
    len_pos = buf.position
    buf.put_int(0)

    # Save the string
    start_pos = buf.position
    self.class.serialize_cstr(buf, val)
    end_pos = buf.position

    # Put the string size in front
    buf.put_int(end_pos - start_pos, len_pos)

    # Go back to where we were
    buf.position = end_pos
  end

  def deserialize_element_name(buf)
    chars = ""
    while 1
      b = buf.get
      break if b == 0
      chars << b.chr
    end
    chars
  end

  def bson_type(o, key)
    case o
    when nil
      NULL
    when Integer
      NUMBER_INT
    when Numeric
      NUMBER
    when String
      # magic awful stuff - the DB requires that a where clause is sent as CODE
      key == "$where" ? CODE : STRING
    when Array
      ARRAY
    when Regexp
      REGEX
    when XGen::Mongo::Driver::ObjectID
      OID
    when true, false
      BOOLEAN
    when Time
      DATE
    when Hash
      OBJECT
    else
      raise "Unknown type of object: #{o.class.name}"
    end
  end

end
