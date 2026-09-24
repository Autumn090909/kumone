import Foundation

/// The JavaScript environment an LX custom-source script is evaluated in.
///
/// LX gives scripts a `globalThis.lx` object plus a Node-flavoured baseline
/// (Buffer, base64, timers, console). JavaScriptCore ships none of that, so this
/// prelude rebuilds it in JS and routes the few things that cannot live in JS —
/// network, crypto, zlib, timers — through the `__kumoneNative` bridge that
/// `LXScriptRuntime` installs before evaluating this file.
///
/// Keeping the shim in JS rather than Swift is deliberate: `Buffer` in
/// particular is used with enough of Node's surface area that expressing it in
/// Swift would mean a hundred tiny bridge calls per script.
enum LXRuntimePrelude {
    static let source = #"""
    (function () {
      'use strict'

      // The host installs these as flat globals. Reassembling them into one
      // object here rather than nesting blocks in Swift keeps the bridge to a
      // single, well-trodden code path.
      var native = {
        httpStart: globalThis.__knHttpStart,
        httpCancel: globalThis.__knHttpCancel,
        log: globalThis.__knLog,
        emit: globalThis.__knEmit,
        cryptoMD5: globalThis.__knCryptoMD5,
        cryptoRandomBytes: globalThis.__knCryptoRandomBytes,
        cryptoAES: globalThis.__knCryptoAES,
        cryptoRSA: globalThis.__knCryptoRSA,
        zlibRun: globalThis.__knZlibRun,
        timerStart: globalThis.__knTimerStart,
        timerClear: globalThis.__knTimerClear,
        actionSettled: globalThis.__knActionSettled
      }
      if (!native.httpStart || !native.actionSettled) {
        throw new Error('Kumone native bridge is missing')
      }

      var B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
      var B64_LOOKUP = (function () {
        var table = {}
        for (var index = 0; index < B64_ALPHABET.length; index++) {
          table[B64_ALPHABET.charAt(index)] = index
        }
        return table
      })()

      function base64Encode(bytes) {
        var out = ''
        var cursor = 0
        for (; cursor + 2 < bytes.length; cursor += 3) {
          var triple = (bytes[cursor] << 16) | (bytes[cursor + 1] << 8) | bytes[cursor + 2]
          out += B64_ALPHABET.charAt((triple >>> 18) & 63)
            + B64_ALPHABET.charAt((triple >>> 12) & 63)
            + B64_ALPHABET.charAt((triple >>> 6) & 63)
            + B64_ALPHABET.charAt(triple & 63)
        }
        var remaining = bytes.length - cursor
        if (remaining === 1) {
          var one = bytes[cursor] << 16
          out += B64_ALPHABET.charAt((one >>> 18) & 63)
            + B64_ALPHABET.charAt((one >>> 12) & 63) + '=='
        } else if (remaining === 2) {
          var two = (bytes[cursor] << 16) | (bytes[cursor + 1] << 8)
          out += B64_ALPHABET.charAt((two >>> 18) & 63)
            + B64_ALPHABET.charAt((two >>> 12) & 63)
            + B64_ALPHABET.charAt((two >>> 6) & 63) + '='
        }
        return out
      }

      function base64Decode(text) {
        var cleaned = String(text).replace(/[^A-Za-z0-9+/]/g, '')
        if (cleaned.length % 4 === 1) cleaned = cleaned.slice(0, cleaned.length - 1)
        var out = []
        var cursor = 0
        while (cursor < cleaned.length) {
          var c0 = B64_LOOKUP[cleaned.charAt(cursor++)]
          var c1 = B64_LOOKUP[cleaned.charAt(cursor++)]
          if (c0 === undefined || c1 === undefined) break
          out.push(((c0 << 2) | (c1 >> 4)) & 255)
          var c2 = B64_LOOKUP[cleaned.charAt(cursor++)]
          if (c2 === undefined) break
          out.push(((c1 << 4) | (c2 >> 2)) & 255)
          var c3 = B64_LOOKUP[cleaned.charAt(cursor++)]
          if (c3 === undefined) break
          out.push(((c2 << 6) | c3) & 255)
        }
        return new Uint8Array(out)
      }

      function hexEncode(bytes) {
        var out = ''
        for (var index = 0; index < bytes.length; index++) {
          out += (bytes[index] < 16 ? '0' : '') + bytes[index].toString(16)
        }
        return out
      }

      function hexDecode(text) {
        var cleaned = String(text).replace(/[^0-9a-fA-F]/g, '')
        var length = Math.floor(cleaned.length / 2)
        var out = new Uint8Array(length)
        for (var index = 0; index < length; index++) {
          out[index] = parseInt(cleaned.substr(index * 2, 2), 16)
        }
        return out
      }

      function utf8Encode(text) {
        var value = String(text)
        var out = []
        for (var index = 0; index < value.length; index++) {
          var code = value.charCodeAt(index)
          if (code < 0x80) {
            out.push(code)
          } else if (code < 0x800) {
            out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f))
          } else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length) {
            var low = value.charCodeAt(index + 1)
            if (low >= 0xdc00 && low <= 0xdfff) {
              var scalar = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
              out.push(
                0xf0 | (scalar >> 18),
                0x80 | ((scalar >> 12) & 0x3f),
                0x80 | ((scalar >> 6) & 0x3f),
                0x80 | (scalar & 0x3f)
              )
              index++
            } else {
              out.push(0xef, 0xbf, 0xbd)
            }
          } else if (code >= 0xd800 && code <= 0xdfff) {
            out.push(0xef, 0xbf, 0xbd)
          } else {
            out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f))
          }
        }
        return new Uint8Array(out)
      }

      function utf8Decode(bytes) {
        var out = ''
        var cursor = 0
        while (cursor < bytes.length) {
          var byte = bytes[cursor++]
          if (byte < 0x80) {
            out += String.fromCharCode(byte)
          } else if (byte >= 0xc0 && byte < 0xe0) {
            out += String.fromCharCode(((byte & 0x1f) << 6) | (bytes[cursor++] & 0x3f))
          } else if (byte >= 0xe0 && byte < 0xf0) {
            out += String.fromCharCode(
              ((byte & 0x0f) << 12) | ((bytes[cursor++] & 0x3f) << 6) | (bytes[cursor++] & 0x3f)
            )
          } else {
            var scalar = ((byte & 0x07) << 18)
              | ((bytes[cursor++] & 0x3f) << 12)
              | ((bytes[cursor++] & 0x3f) << 6)
              | (bytes[cursor++] & 0x3f)
            scalar -= 0x10000
            out += String.fromCharCode(0xd800 + (scalar >> 10), 0xdc00 + (scalar & 0x3ff))
          }
        }
        return out
      }

      function latin1Encode(text) {
        var value = String(text)
        var out = new Uint8Array(value.length)
        for (var index = 0; index < value.length; index++) {
          out[index] = value.charCodeAt(index) & 255
        }
        return out
      }

      function latin1Decode(bytes) {
        var out = ''
        for (var index = 0; index < bytes.length; index++) {
          out += String.fromCharCode(bytes[index])
        }
        return out
      }

      function encodeText(value, encoding) {
        var normalized = String(encoding || 'utf8').toLowerCase()
        if (normalized === 'hex') return hexDecode(value)
        if (normalized === 'base64') return base64Decode(value)
        if (normalized === 'latin1' || normalized === 'binary') return latin1Encode(value)
        return utf8Encode(value)
      }

      function decodeText(bytes, encoding) {
        var normalized = String(encoding || 'utf8').toLowerCase()
        if (normalized === 'hex') return hexEncode(bytes)
        if (normalized === 'base64') return base64Encode(bytes)
        if (normalized === 'latin1' || normalized === 'binary') return latin1Decode(bytes)
        return utf8Decode(bytes)
      }

      function toBytes(value, encoding) {
        if (value === null || value === undefined) return new Uint8Array(0)
        if (value instanceof Uint8Array) return value
        if (value instanceof ArrayBuffer) return new Uint8Array(value)
        if (ArrayBuffer.isView(value)) {
          return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
        }
        if (Array.isArray(value)) {
          var out = new Uint8Array(value.length)
          for (var index = 0; index < value.length; index++) out[index] = value[index] & 255
          return out
        }
        if (typeof value === 'number') return new Uint8Array(value)
        return encodeText(String(value), encoding)
      }

      class KumoneBuffer extends Uint8Array {
        static from(value, encoding) {
          if (value instanceof KumoneBuffer) return value
          return new KumoneBuffer(toBytes(value, encoding))
        }

        static alloc(size, fill) {
          var out = new KumoneBuffer(Math.max(0, size | 0))
          if (fill !== undefined) {
            out.fill(typeof fill === 'string' ? (fill.charCodeAt(0) & 255) : fill)
          }
          return out
        }

        static allocUnsafe(size) {
          return new KumoneBuffer(Math.max(0, size | 0))
        }

        static isBuffer(value) {
          return value instanceof Uint8Array
        }

        static byteLength(value, encoding) {
          return toBytes(value, encoding).length
        }

        static concat(list, totalLength) {
          var chunks = []
          var total = 0
          var index
          for (index = 0; index < list.length; index++) {
            var chunk = toBytes(list[index])
            chunks.push(chunk)
            total += chunk.length
          }
          var size = typeof totalLength === 'number' ? totalLength : total
          var out = new KumoneBuffer(size)
          var offset = 0
          for (index = 0; index < chunks.length && offset < size; index++) {
            var piece = chunks[index]
            var room = size - offset
            var slice = piece.length > room ? piece.subarray(0, room) : piece
            out.set(slice, offset)
            offset += slice.length
          }
          return out
        }

        toString(encoding, start, end) {
          var from = typeof start === 'number' ? start : 0
          var to = typeof end === 'number' ? end : this.length
          return decodeText(
            this.subarray(from, to),
            typeof encoding === 'string' ? encoding : 'utf8'
          )
        }

        slice(start, end) {
          return new KumoneBuffer(this.subarray(start, end))
        }

        equals(other) {
          var target = toBytes(other)
          if (target.length !== this.length) return false
          for (var index = 0; index < this.length; index++) {
            if (this[index] !== target[index]) return false
          }
          return true
        }

        compare(other) {
          var target = toBytes(other)
          var shared = Math.min(this.length, target.length)
          for (var index = 0; index < shared; index++) {
            if (this[index] !== target[index]) return this[index] < target[index] ? -1 : 1
          }
          if (this.length === target.length) return 0
          return this.length < target.length ? -1 : 1
        }

        copy(target, targetStart, sourceStart, sourceEnd) {
          var destination = toBytes(target)
          var start = targetStart || 0
          var from = sourceStart || 0
          var to = typeof sourceEnd === 'number' ? sourceEnd : this.length
          var count = 0
          for (var index = from; index < to && start + count < destination.length; index++) {
            destination[start + count] = this[index]
            count++
          }
          return count
        }

        write(text, offset, length, encoding) {
          var start = offset || 0
          var bytes = typeof encoding === 'string' ? encodeText(text, encoding) : toBytes(text)
          var limit = typeof length === 'number' ? Math.min(bytes.length, length) : bytes.length
          for (var index = 0; index < limit && start + index < this.length; index++) {
            this[start + index] = bytes[index]
          }
          return limit
        }

        toJSON() {
          return { type: 'Buffer', data: Array.prototype.slice.call(this) }
        }

        readUInt8(offset) { return this[offset] }

        readInt8(offset) {
          var value = this[offset]
          return value > 127 ? value - 256 : value
        }

        readUInt16BE(offset) { return (this[offset] << 8) | this[offset + 1] }

        readUInt16LE(offset) { return this[offset] | (this[offset + 1] << 8) }

        readUInt32BE(offset) {
          return ((this[offset] << 24) | (this[offset + 1] << 16)
            | (this[offset + 2] << 8) | this[offset + 3]) >>> 0
        }

        readUInt32LE(offset) {
          return (this[offset] | (this[offset + 1] << 8)
            | (this[offset + 2] << 16) | (this[offset + 3] << 24)) >>> 0
        }

        readInt32BE(offset) { return this.readUInt32BE(offset) | 0 }

        readInt32LE(offset) { return this.readUInt32LE(offset) | 0 }

        writeUInt8(value, offset) { this[offset] = value & 255; return offset + 1 }

        writeUInt16BE(value, offset) {
          this[offset] = (value >>> 8) & 255
          this[offset + 1] = value & 255
          return offset + 2
        }

        writeUInt16LE(value, offset) {
          this[offset] = value & 255
          this[offset + 1] = (value >>> 8) & 255
          return offset + 2
        }

        writeUInt32BE(value, offset) {
          this[offset] = (value >>> 24) & 255
          this[offset + 1] = (value >>> 16) & 255
          this[offset + 2] = (value >>> 8) & 255
          this[offset + 3] = value & 255
          return offset + 4
        }

        writeUInt32LE(value, offset) {
          this[offset] = value & 255
          this[offset + 1] = (value >>> 8) & 255
          this[offset + 2] = (value >>> 16) & 255
          this[offset + 3] = (value >>> 24) & 255
          return offset + 4
        }

        indexOf(value, byteOffset, encoding) {
          var needle = typeof value === 'number'
            ? new Uint8Array([value & 255])
            : toBytes(value, encoding)
          var start = typeof byteOffset === 'number' ? byteOffset : 0
          if (needle.length === 0) return Math.min(start, this.length)
          for (var index = start; index + needle.length <= this.length; index++) {
            var hit = true
            for (var inner = 0; inner < needle.length; inner++) {
              if (this[index + inner] !== needle[inner]) { hit = false; break }
            }
            if (hit) return index
          }
          return -1
        }

        includes(value, byteOffset, encoding) {
          return this.indexOf(value, byteOffset, encoding) !== -1
        }
      }

      var Buffer = KumoneBuffer
      // LX scripts are evaluated at global scope, so an IIFE-local `var` is
      // invisible to them: real sources call bare `Buffer.from(...)` the way
      // they would under Node, and `lx.utils.buffer` alone would leave them
      // with a ReferenceError. Publish it on the global object.
      globalThis.Buffer = Buffer

      if (typeof globalThis.TextEncoder === 'undefined') {
        globalThis.TextEncoder = function TextEncoder() {}
        globalThis.TextEncoder.prototype.encode = function (text) { return utf8Encode(text) }
      }
      if (typeof globalThis.TextDecoder === 'undefined') {
        globalThis.TextDecoder = function TextDecoder() {}
        globalThis.TextDecoder.prototype.decode = function (bytes) { return utf8Decode(toBytes(bytes)) }
      }
      if (typeof globalThis.btoa === 'undefined') {
        globalThis.btoa = function (text) { return base64Encode(latin1Encode(text)) }
        globalThis.atob = function (text) { return latin1Decode(base64Decode(text)) }
      }

      // --------------------------------------------------------------- timers --

      var timerSequence = 1
      var timers = {}

      globalThis.__kumoneTimerFire = function (id) {
        var entry = timers[id]
        if (!entry) return
        if (!entry.repeat) delete timers[id]
        try {
          entry.handler.apply(null, entry.args)
        } catch (error) {
          console.error('timer handler threw: ' + describeError(error))
        }
      }

      function scheduleTimer(handler, delay, args, repeat) {
        if (typeof handler !== 'function') throw new TypeError('timer handler must be a function')
        var id = timerSequence++
        timers[id] = { handler: handler, args: args, repeat: repeat }
        native.timerStart(id, Math.max(0, Number(delay) || 0), repeat)
        return id
      }

      globalThis.setTimeout = function (handler, delay) {
        return scheduleTimer(handler, delay, Array.prototype.slice.call(arguments, 2), false)
      }
      globalThis.setInterval = function (handler, delay) {
        return scheduleTimer(handler, delay, Array.prototype.slice.call(arguments, 2), true)
      }
      globalThis.clearTimeout = function (id) {
        delete timers[id]
        native.timerClear(id)
      }
      globalThis.clearInterval = globalThis.clearTimeout
      globalThis.setImmediate = function (handler) {
        return scheduleTimer(handler, 0, Array.prototype.slice.call(arguments, 1), false)
      }
      globalThis.queueMicrotask = function (handler) {
        Promise.resolve().then(handler)
      }

      // -------------------------------------------------------------- console --

      function describeError(error) {
        if (error === null || error === undefined) return 'Unknown error'
        if (typeof error === 'string') return error
        if (error.message) return String(error.message)
        try { return JSON.stringify(error) } catch (ignored) { return String(error) }
      }

      function formatArguments(values) {
        var parts = []
        for (var index = 0; index < values.length; index++) {
          var value = values[index]
          if (typeof value === 'string') {
            parts.push(value)
          } else if (value instanceof Error) {
            parts.push(value.stack || describeError(value))
          } else {
            try { parts.push(JSON.stringify(value)) } catch (ignored) { parts.push(String(value)) }
          }
        }
        return parts.join(' ')
      }

      if (typeof globalThis.console === 'undefined') {
        globalThis.console = {}
      }
      var consoleLevels = ['log', 'info', 'warn', 'error', 'debug', 'trace']
      for (var consoleIndex = 0; consoleIndex < consoleLevels.length; consoleIndex++) {
        (function (level) {
          globalThis.console[level] = function () {
            try { native.log(level, formatArguments(arguments)) } catch (ignored) {}
          }
        })(consoleLevels[consoleIndex])
      }

      // ---------------------------------------------------------- lx.http glue --

      var pendingRequests = {}
      var requestSequence = 1

      globalThis.__kumoneHTTPComplete = function (id, errorMessage, responseJSON) {
        var entry = pendingRequests[id]
        if (!entry) return
        delete pendingRequests[id]
        if (errorMessage) {
          entry.reject(new Error(errorMessage))
          return
        }
        var response
        try {
          response = JSON.parse(responseJSON)
        } catch (ignored) {
          response = { statusCode: 0, statusMessage: '', headers: {}, body: null, raw: '' }
        }
        if (!response || typeof response !== 'object') {
          response = { statusCode: 0, statusMessage: '', headers: {}, body: null, raw: '' }
        }
        entry.resolve(response)
      }

      function lxRequest(url, options, callback) {
        var settings = options || {}
        var id = requestSequence++
        var settled = false
        var settle = {}
        var promise = new Promise(function (resolve, reject) {
          settle.resolve = resolve
          settle.reject = reject
        })

        pendingRequests[id] = {
          resolve: function (response) {
            if (settled) return
            settled = true
            if (typeof callback === 'function') callback(null, response, response.body)
            settle.resolve(response)
          },
          reject: function (error) {
            if (settled) return
            settled = true
            var reason = error instanceof Error ? error : new Error(String(error))
            if (typeof callback === 'function') callback(reason, null, null)
            settle.reject(reason)
          }
        }

        var payload = {
          method: settings.method || 'get',
          headers: settings.headers || null,
          body: settings.body === undefined ? null : settings.body,
          form: settings.form || null,
          formData: settings.formData || null,
          timeout: Number(settings.timeout) || 0
        }

        try {
          native.httpStart(id, String(url), JSON.stringify(payload))
        } catch (error) {
          pendingRequests[id].reject(error)
        }

        if (typeof callback === 'function') {
          // A callback-style caller gets LX's documented cancel handle back.
          // The promise still exists, so swallow its rejection to keep the
          // engine quiet about a result nobody is listening for.
          promise.catch(function () {})
          return function cancel() {
            try { native.httpCancel(id) } catch (ignored) {}
            var entry = pendingRequests[id]
            if (entry) {
              delete pendingRequests[id]
              entry.reject(new Error('Request cancelled'))
            }
          }
        }
        return promise
      }

      // ------------------------------------------------------------ lx.utils --

      function parseEnvelope(raw) {
        var envelope
        try {
          envelope = JSON.parse(raw)
        } catch (ignored) {
          throw new Error('Kumone crypto bridge returned invalid data')
        }
        if (!envelope || envelope.ok !== true) {
          throw new Error((envelope && envelope.error) || 'Kumone crypto bridge failed')
        }
        return envelope.value
      }

      function requireBase64(value) {
        var bytes = toBytes(value)
        return base64Encode(bytes)
      }

      var crypto = {
        md5: function (input) {
          return native.cryptoMD5(String(input))
        },
        randomBytes: function (size) {
          return Buffer.from(parseEnvelope(native.cryptoRandomBytes(Number(size) || 0)), 'base64')
        },
        aesEncrypt: function (data, mode, key, iv) {
          var raw = native.cryptoAES(
            requireBase64(data),
            String(mode),
            requireBase64(key),
            iv === null || iv === undefined ? '' : requireBase64(iv),
            true
          )
          return Buffer.from(parseEnvelope(raw), 'base64')
        },
        aesDecrypt: function (data, mode, key, iv) {
          var raw = native.cryptoAES(
            requireBase64(data),
            String(mode),
            requireBase64(key),
            iv === null || iv === undefined ? '' : requireBase64(iv),
            false
          )
          return Buffer.from(parseEnvelope(raw), 'base64')
        },
        rsaEncrypt: function (data, key) {
          var raw = native.cryptoRSA(requireBase64(data), String(key))
          return Buffer.from(parseEnvelope(raw), 'base64')
        }
      }

      var pendingZlib = {}
      var zlibSequence = 1

      globalThis.__kumoneZlibComplete = function (id, errorMessage, base64Payload) {
        var entry = pendingZlib[id]
        if (!entry) return
        delete pendingZlib[id]
        if (errorMessage) {
          entry.reject(new Error(errorMessage))
          return
        }
        entry.resolve(Buffer.from(base64Payload || '', 'base64'))
      }

      function zlibOperation(operation, data) {
        var id = zlibSequence++
        var promise = new Promise(function (resolve, reject) {
          pendingZlib[id] = { resolve: resolve, reject: reject }
        })
        try {
          native.zlibRun(id, operation, requireBase64(data))
        } catch (error) {
          delete pendingZlib[id]
          return Promise.reject(error)
        }
        return promise
      }

      // --------------------------------------------------------- script glue --

      var requestHandlers = {}
      var EVENT_NAMES = {
        inited: 'inited',
        request: 'request',
        updateAlert: 'updateAlert'
      }

      var scriptInfo = {
        name: '',
        description: '',
        version: '',
        author: '',
        homepage: '',
        rawScript: ''
      }

      globalThis.__kumoneSetScriptInfo = function (json) {
        try {
          var parsed = JSON.parse(json)
          // Mutate the object `lx.currentScriptInfo` already points at. Rebinding
          // `scriptInfo` to a fresh literal would leave scripts holding the empty
          // initial object forever, since `lx` captures the reference, not the
          // binding.
          scriptInfo.name = parsed.name || ''
          scriptInfo.description = parsed.description || ''
          scriptInfo.version = parsed.version || ''
          scriptInfo.author = parsed.author || ''
          scriptInfo.homepage = parsed.homepage || ''
          scriptInfo.rawScript = parsed.rawScript || ''
        } catch (ignored) {}
      }

      globalThis.lx = {
        version: '2.0.0',
        env: 'desktop',
        currentScriptInfo: scriptInfo,
        EVENT_NAMES: EVENT_NAMES,
        on: function (eventName, handler) {
          if (typeof handler !== 'function') {
            throw new TypeError('lx.on requires a function handler')
          }
          requestHandlers[String(eventName)] = handler
        },
        send: function (eventName, data) {
          var encoded
          try {
            encoded = JSON.stringify(data === undefined ? null : data, function (key, value) {
              return typeof value === 'function' ? undefined : value
            })
          } catch (error) {
            encoded = JSON.stringify({ error: describeError(error) })
          }
          try { native.emit(String(eventName), encoded) } catch (ignored) {}
        },
        request: lxRequest,
        utils: {
          buffer: {
            from: function (value, encoding) { return Buffer.from(value, encoding) },
            bufToString: function (buffer, format) {
              return Buffer.from(buffer).toString(format || 'utf8')
            }
          },
          crypto: crypto,
          zlib: {
            inflate: function (buffer) { return zlibOperation('inflate', buffer) },
            deflate: function (buffer) { return zlibOperation('deflate', buffer) }
          }
        }
      }

      // Exposed for the host: runs the script's request handler for one action
      // and reports the settled value back through the native bridge.
      globalThis.__kumoneRunAction = function (requestID, sourceKey, action, quality, musicInfoJSON) {
        var promise
        try {
          var handler = requestHandlers[EVENT_NAMES.request]
          if (typeof handler !== 'function') {
            throw new Error('脚本没有注册 request 事件')
          }
          var musicInfo = JSON.parse(musicInfoJSON)
          var info = action === 'musicUrl'
            ? { type: quality, musicInfo: musicInfo }
            : { musicInfo: musicInfo }
          promise = Promise.resolve(handler({ source: sourceKey, action: action, info: info }))
        } catch (error) {
          promise = Promise.reject(error)
        }
        promise.then(
          function (value) {
            var encoded
            try {
              encoded = JSON.stringify(value === undefined ? null : value)
            } catch (error) {
              encoded = JSON.stringify(String(value))
            }
            native.actionSettled(requestID, null, encoded)
          },
          function (error) {
            native.actionSettled(requestID, describeError(error), null)
          }
        )
      }
    })()
    """#
}
