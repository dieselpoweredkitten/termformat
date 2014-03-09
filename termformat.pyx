# coding: utf-8
# cython: boundscheck=False
# cython: wraparound=False
from struct import Struct

__version__ = "0.1.2"

try:
  # Python 2.7
  long = long
except NameError:
  # Python 3.3
  long = int

cdef str DEFAULT_ENCODING
cdef bytes ERL_NEW_FLOAT, ERL_COMPRESSED, ERL_SMALL_INT, ERL_INT, ERL_FLOAT, ERL_ATOM, ERL_SMALL_TUPLE, ERL_LARGE_TUPLE, ERL_NIL, ERL_STRING, ERL_BINARY, ERL_SMALL_BIGNUM, ERL_LARGE_BIGNUM, ERL_MAGIC

DEFAULT_ENCODING = "utf-8"

ERL_NEW_FLOAT = b'F'
ERL_COMPRESSED = b'P'
ERL_SMALL_INT = b'a'
ERL_INT = b'b'
ERL_FLOAT = b'c'
ERL_ATOM = b'd'
ERL_SMALL_TUPLE = b'h'
ERL_LARGE_TUPLE = b'i'
ERL_NIL = b'j'
ERL_STRING = b'k'
ERL_LIST = b'l'
ERL_BINARY = b'm'
ERL_SMALL_BIGNUM = b'n'
ERL_LARGE_BIGNUM = b'o'
ERL_MAGIC = b'\x83'


_char = Struct(">B")
_int4 = Struct(">I")
_int2 = Struct(">H")
_signed_int4 = Struct(">i")
_float = Struct(">d")

_char_pack = _char.pack
_int4_pack = _int4.pack
_int2_pack = _int2.pack
_signed_int4_pack = _signed_int4.pack
_float_pack = _float.pack

_char_unpack = _char.unpack
_int4_unpack = _int4.unpack
_int2_unpack = _int2.unpack
_signed_int4_unpack = _signed_int4.unpack
_float_unpack = _float.unpack


cdef bytes encode_term(object term):
  cdef int length = 0
  term_type = type(term)
  if term_type in (int, long):
    if 0 <= term <= 255:
      return ERL_SMALL_INT + _char_pack(term)
    elif -2147483648 <= term <= 2147483647:
      return ERL_INT + _signed_int4_pack(term)
    else:
      sign, term = (0, term) if term >= 0 else (1, -term)
      body = b""
      while term:
        body += _char_pack(term & 0xff)
        term >>= 8
      length = len(body)
      sign = _char_pack(sign)
      if length <= 255:
        return ERL_SMALL_BIGNUM + _char_pack(length) + sign + body
      elif length <= 4294967295:
        return ERL_LARGE_BIGNUM + _int4_pack(length) + sign + body
      else:
        raise ValueError("Invalid BIGNUM_EXT length: {0}".format(length))
  elif term_type is float:
    body = "{0:.20e}".format(term)
    body = body.encode(DEFAULT_ENCODING)
    body = body + b"\x00" * (31 - len(body))
    return ERL_FLOAT + body
  elif term_type is bytes:
    if term.startswith(b":"):
      atom_name = term[1:]
      length = len(atom_name)
      if not length or length > 255:
        raise ValueError("Invalid ATOM_EXT length: {0}".format(term))
      else:
        return ERL_ATOM + _int2_pack(length) + atom_name
    else:
      length = len(term)
      if length <= 4294967295:
        return ERL_BINARY + _int4_pack(length) + term
      else:
        raise ValueError("Invalid BINARY_EXT length: {0}".format(length))
  elif term_type in (str, unicode):
    new_term = term.encode(DEFAULT_ENCODING)
    return encode_term(new_term)
  elif term_type is tuple:
    length = len(term)
    if length <= 255:
      tuple_type, tuple_length = ERL_SMALL_TUPLE, _char_pack(length)
    elif length <= 4294967295:
      tuple_type, tuple_length = ERL_LARGE_TUPLE, _int4_pack(length)
    else:
      raise ValueError("Invalid TUPLE_EXT length: {0}".format(length))
    content = tuple_type + tuple_length
    for item in term:
      content += encode_term(item)
    return content
  elif term_type is list:
    length = len(term)
    if not length:
      return ERL_NIL
    elif length <= 4294967295:
      body = _int4_pack(length)
      for item in term:
        body += encode_term(item)
      return ERL_LIST + body + ERL_NIL
    else:
      raise ValueError("Invalid LIST_EXT length: {0}".format(length))
  else:
    raise ValueError("Unknown datatype: {0}".format(term_type))


cpdef encode(object term):
  BODY = encode_term(term)
  return ERL_MAGIC + BODY


cdef object decode_term(bytes term):
  cdef bytes term_type, body
  term_type = term[:1]
  if term_type == ERL_SMALL_INT:
    body = term[1:2]
    if not body:
      raise ValueError("Incomplete SMALL_INT_EXT length: expected 1, got 0")
    else:
      return _char_unpack(body)[0], term[2:]
  elif term_type == ERL_INT:
    body = term[1:5]
    if len(body) < 4:
      raise ValueError("Incomplete INT_EXT length: expected 4, got {0}".format(len(body)))
    else:
      return _signed_int4_unpack(body)[0], term[5:]
  elif term_type in (ERL_SMALL_BIGNUM, ERL_LARGE_BIGNUM):
    if term_type == ERL_SMALL_BIGNUM:
      length, sign = _char_unpack(term[1:2])[0], ord(term[2:3])
      tail = term[3:]
    else:
      length, sign = _int4_unpack(term[1:5])[0], ord(term[5:6])
      tail = term[4:]
    n = 0
    if length:
      for i in tail[length-1::-1]:
        if isinstance(i, bytes):
          i = ord(i)
        n = (n << 8) | i
      if sign:
        n = -n
    return n, tail[length:]
  elif term_type == ERL_FLOAT:
    body = term[1:32]
    if len(body) < 31:
      raise ValueError("Incomplete FLOAT_EXT length: expected 31, got {0}".format(len(body)))
    else:
      body = body.split(b"\x00")[0]
      return float(body), term[32:]
  elif term_type == ERL_NEW_FLOAT:
    body = term[1:9]
    if len(body) < 8:
      raise ValueError("Incomplete NEW_FLOAT_EXT length: expected 8, got {0}".format(len(body)))
    else:
      return _float_unpack(body)[0], term[9:]
  elif term_type == ERL_STRING:
    length = _int2_unpack(term[1:3])[0]
    body = term[3:length + 3]
    if length > 65535:
      raise ValueError("Invalid STRING_EXT length: {0}".format(length))
    elif length > len(body):
      raise ValueError("Incomplete STRING_EXT length: expected {0}, got {1}".format(length, len(body)))
    else:
      return body.decode(DEFAULT_ENCODING), term[length:]
  elif term_type == ERL_BINARY:
    length = _int4_unpack(term[1:5])[0] + 5
    body = term[5:length]
    if length > 4294967295:
      raise ValueError("Invalid BINARY_EXT length: {0}".format(length))
    elif length > len(body) + 5:
      raise ValueError("Incomplete BINARY_EXT length: expected {0}, got {1}".format(length, len(body)))
    else:
      return body.decode(DEFAULT_ENCODING), term[length:]
  elif term_type == ERL_SMALL_TUPLE:
    length, = _char_unpack(term[1:2])
    if length > 255:
      raise ValueError("Invalid SMALL_TUPLE_EXT length: {0}".format(length))
    else:
      objects, tail = decode_iterable(length, term[2:])
      return tuple(objects), tail
  elif term_type == ERL_LARGE_TUPLE:
    length, = _int4_unpack(term[1:5])
    if length > 4294967295:
      raise ValueError("Invalid LARGE_TUPLE_EXT length: {0}".format(length))
    else:
      objects, tail = decode_iterable(length, term[5:])
      return tuple(objects), tail
  elif term_type == ERL_LIST:
    length, = _int4_unpack(term[1:5])
    if length > 4294967295:
      raise ValueError("Invalid LIST_EXT length: {0}".format(length))
    else:
      objects, tail = decode_iterable(length, term[5:])
      return objects, tail
  elif term_type == ERL_ATOM:
    atom_length = _int2_unpack(term[1:3])[0] + 3
    atom_name = term[3:atom_length]
    if atom_length > len(atom_name) + 3:
      raise ValueError("Invalid ATOM_EXT length: expected {0}, got {1}".format(atom_length, len(atom_name)))
    else:
      atom_name = atom_name.decode(DEFAULT_ENCODING)
      return ":" + atom_name, term[atom_length:]
  elif term_type == ERL_NIL:
    return [], term[1:]
  else:
    raise ValueError("Invalid term type: {0}".format(term_type))


cdef tuple decode_iterable(int length, bytes source):
  cdef list objects = []
  for i in xrange(length):
    term, source = decode_term(source)
    objects.append(term)
  else:
    if source[:1] == ERL_NIL:
      source = source[1:]
  return objects, source


cpdef decode(bytes term):
  if term[:1] != ERL_MAGIC:
    raise ValueError("Invalid external term format version")
  return decode_term(term[1:])[0]
