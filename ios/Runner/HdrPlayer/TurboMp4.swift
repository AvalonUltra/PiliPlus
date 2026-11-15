import Foundation

// Fragmented MP4 (DASH .m4s) → non-fragmented MP4 sample tables.
//
// AVPlayer's HLS engine cannot play faster than 2x: any rate above 2.0
// switches it to trick play (keyframes only), which is what long-press
// speed-ups looked like ("像快进"). Progressive MP4 has no such limit, but
// AVFoundation opens a fragmented MP4 by reading every moof in the file first.
// So for fast rates we describe a window of the very same CDN bytes as an
// ordinary MP4: a synthesized moov with complete sample tables whose chunk
// offsets point into a virtual mdat that maps onto the source files.

enum TurboMp4Error: LocalizedError {
    case malformed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let message): return "turbo mp4 malformed: \(message)"
        case .unsupported(let message): return "turbo mp4 unsupported: \(message)"
        }
    }
}

// MARK: - Byte access

@inline(__always) func turboU16(_ b: [UInt8], _ o: Int) -> UInt16 {
    (UInt16(b[o]) << 8) | UInt16(b[o + 1])
}

@inline(__always) func turboU32(_ b: [UInt8], _ o: Int) -> UInt32 {
    (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
}

@inline(__always) func turboU64(_ b: [UInt8], _ o: Int) -> UInt64 {
    (UInt64(turboU32(b, o)) << 32) | UInt64(turboU32(b, o + 4))
}

struct TurboBox {
    let type: String
    let offset: Int
    let size: Int
    let headerSize: Int

    var payload: Int { offset + headerSize }
    var end: Int { offset + size }
}

/// Top-level boxes in `b[from..<to]`. Throws on a box that overruns the range.
func turboBoxes(_ b: [UInt8], from: Int, to: Int) throws -> [TurboBox] {
    var result: [TurboBox] = []
    var o = from
    while o + 8 <= to {
        var size = Int(turboU32(b, o))
        var header = 8
        if size == 1 {
            guard o + 16 <= to else { throw TurboMp4Error.malformed("truncated largesize") }
            let large = turboU64(b, o + 8)
            guard large <= UInt64(Int32.max) else { throw TurboMp4Error.malformed("box too large") }
            size = Int(large)
            header = 16
        } else if size == 0 {
            size = to - o
        }
        guard size >= header, o + size <= to else {
            throw TurboMp4Error.malformed("box overruns parent at \(o)")
        }
        let type = String(bytes: b[(o + 4) ..< (o + 8)], encoding: .isoLatin1) ?? "????"
        result.append(TurboBox(type: type, offset: o, size: size, headerSize: header))
        o += size
    }
    return result
}

/// Reads only the header of the box at `o` (the box may extend past `b`).
func turboBoxHeader(_ b: [UInt8], at o: Int) -> TurboBox? {
    guard o >= 0, o + 8 <= b.count else { return nil }
    var size = Int(turboU32(b, o))
    var header = 8
    if size == 1 {
        guard o + 16 <= b.count else { return nil }
        let large = turboU64(b, o + 8)
        // Media boxes (mdat) can be large; anything beyond 2^53 is garbage.
        guard large < (1 << 53) else { return nil }
        size = Int(large)
        header = 16
    }
    guard size >= header else { return nil }
    let type = String(bytes: b[(o + 4) ..< (o + 8)], encoding: .isoLatin1) ?? "????"
    return TurboBox(type: type, offset: o, size: size, headerSize: header)
}

func turboChild(_ b: [UInt8], _ parent: TurboBox, _ type: String) throws -> TurboBox? {
    try turboBoxes(b, from: parent.payload, to: parent.end).first { $0.type == type }
}

// MARK: - Init segment

struct TurboTrexDefaults {
    var duration: UInt32 = 0
    var size: UInt32 = 0
    var flags: UInt32 = 0
}

/// The parts of a DASH init segment (ftyp+moov) the movie builder needs.
struct TurboTrackInit {
    let bytes: [UInt8]
    let tkhd: TurboBox
    let mdhd: TurboBox
    let hdlr: TurboBox
    let minfChildren: [TurboBox]  // everything in minf except stbl
    let stsd: TurboBox
    let trackId: UInt32
    let timescale: UInt32
    let isVideo: Bool
    let trex: TurboTrexDefaults
    /// elst media_time of the (single) media edit; 0 without an edit list.
    let mediaTime: Int64

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        let top = try turboBoxes(bytes, from: 0, to: bytes.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else {
            throw TurboMp4Error.malformed("no moov")
        }
        let moovChildren = try turboBoxes(bytes, from: moov.payload, to: moov.end)
        let traks = moovChildren.filter { $0.type == "trak" }
        guard traks.count == 1, let trak = traks.first else {
            throw TurboMp4Error.unsupported("expected one trak, got \(traks.count)")
        }
        let trakChildren = try turboBoxes(bytes, from: trak.payload, to: trak.end)
        guard let tkhd = trakChildren.first(where: { $0.type == "tkhd" }),
              let mdia = trakChildren.first(where: { $0.type == "mdia" })
        else { throw TurboMp4Error.malformed("trak without tkhd/mdia") }
        self.tkhd = tkhd
        guard tkhd.size >= tkhd.headerSize + 24 else { throw TurboMp4Error.malformed("short tkhd") }
        let tkhdVersion = bytes[tkhd.payload]
        guard tkhd.size >= tkhd.headerSize + (tkhdVersion == 1 ? 36 : 24) else {
            throw TurboMp4Error.malformed("short tkhd")
        }
        trackId = turboU32(bytes, tkhd.payload + (tkhdVersion == 1 ? 20 : 12))

        var mediaTime: Int64 = 0
        if let edts = trakChildren.first(where: { $0.type == "edts" }),
           let elst = try turboChild(bytes, edts, "elst") {
            let version = bytes[elst.payload]
            guard elst.size >= elst.headerSize + 8 else { throw TurboMp4Error.malformed("short elst") }
            let count = Int(turboU32(bytes, elst.payload + 4))
            guard count <= 64 else { throw TurboMp4Error.unsupported("\(count) edits") }
            let entrySize = version == 1 ? 20 : 12
            guard elst.payload + 8 + count * entrySize <= elst.end else {
                throw TurboMp4Error.malformed("short elst")
            }
            var mediaEdits = 0
            for i in 0 ..< count {
                let p = elst.payload + 8 + i * entrySize
                let time: Int64 = version == 1
                    ? Int64(bitPattern: turboU64(bytes, p + 8))
                    : Int64(Int32(bitPattern: turboU32(bytes, p + 4)))
                if time == -1 {
                    // An empty edit delays the whole track; the window maths
                    // below assumes presentation = decode + cto - mediaTime.
                    throw TurboMp4Error.unsupported("empty edit")
                }
                mediaEdits += 1
                mediaTime = time
            }
            if mediaEdits > 1 { throw TurboMp4Error.unsupported("\(mediaEdits) media edits") }
        }
        self.mediaTime = mediaTime

        let mdiaChildren = try turboBoxes(bytes, from: mdia.payload, to: mdia.end)
        guard let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }),
              let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
              let minf = mdiaChildren.first(where: { $0.type == "minf" })
        else { throw TurboMp4Error.malformed("mdia incomplete") }
        self.mdhd = mdhd
        self.hdlr = hdlr
        let mdhdVersion = bytes[mdhd.payload]
        guard mdhd.size >= mdhd.headerSize + (mdhdVersion == 1 ? 32 : 20) else {
            throw TurboMp4Error.malformed("short mdhd")
        }
        timescale = turboU32(bytes, mdhd.payload + (mdhdVersion == 1 ? 20 : 12))
        guard timescale > 0 else { throw TurboMp4Error.malformed("timescale 0") }
        guard hdlr.size >= hdlr.headerSize + 12 else { throw TurboMp4Error.malformed("short hdlr") }
        let handler = String(bytes: bytes[(hdlr.payload + 8) ..< (hdlr.payload + 12)], encoding: .isoLatin1)
        guard handler == "vide" || handler == "soun" else {
            throw TurboMp4Error.unsupported("handler \(handler ?? "?")")
        }
        isVideo = handler == "vide"

        let minfChildren = try turboBoxes(bytes, from: minf.payload, to: minf.end)
        guard let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stsd = try turboChild(bytes, stbl, "stsd")
        else { throw TurboMp4Error.malformed("no stbl/stsd") }
        self.stsd = stsd
        self.minfChildren = minfChildren.filter { $0.type != "stbl" }

        var trex = TurboTrexDefaults()
        if let mvex = moovChildren.first(where: { $0.type == "mvex" }) {
            for box in try turboBoxes(bytes, from: mvex.payload, to: mvex.end) where box.type == "trex" {
                guard box.size >= box.headerSize + 24 else { continue }
                // version/flags, track_ID, sample_description_index, then defaults.
                if turboU32(bytes, box.payload + 4) == trackId {
                    trex.duration = turboU32(bytes, box.payload + 12)
                    trex.size = turboU32(bytes, box.payload + 16)
                    trex.flags = turboU32(bytes, box.payload + 20)
                }
            }
        }
        self.trex = trex
    }
}

// MARK: - Fragments

/// Sample tables of one moof (+ the absolute source offsets of its data).
struct TurboFragment {
    var baseDecodeTime: UInt64 = 0
    var durations: [UInt32] = []
    var sizes: [UInt32] = []
    var sync: [Bool] = []
    var ctos: [Int32] = []
    /// One entry per trun: absolute source offset of its first sample and
    /// the number of samples (samples of a trun are contiguous).
    var chunks: [(offset: UInt64, count: Int)] = []

    var duration: UInt64 { durations.reduce(0) { $0 + UInt64($1) } }
    var sampleCount: Int { durations.count }
}

private let sampleIsNonSync: UInt32 = 0x0001_0000

/// Parses the moof box at `b[at...]`, which sits at absolute source offset
/// `moofOffset`.
func turboParseMoof(
    _ b: [UInt8],
    at start: Int,
    moofOffset: UInt64,
    track: TurboTrackInit
) throws -> TurboFragment {
    guard let moof = turboBoxHeader(b, at: start), moof.type == "moof" else {
        throw TurboMp4Error.malformed("expected moof")
    }
    guard moof.end <= b.count else { throw TurboMp4Error.malformed("truncated moof") }
    var fragment = TurboFragment()
    var haveTfdt = false
    var previousTrafEnd: UInt64?
    for traf in try turboBoxes(b, from: moof.payload, to: moof.end) where traf.type == "traf" {
        let children = try turboBoxes(b, from: traf.payload, to: traf.end)
        guard let tfhd = children.first(where: { $0.type == "tfhd" }) else {
            throw TurboMp4Error.malformed("traf without tfhd")
        }
        guard tfhd.size >= tfhd.headerSize + 8 else { throw TurboMp4Error.malformed("short tfhd") }
        let tfhdFlags = turboU32(b, tfhd.payload) & 0x00FF_FFFF
        let trackId = turboU32(b, tfhd.payload + 4)
        var q = tfhd.payload + 8
        var base: UInt64
        var defaultDuration = track.trex.duration
        var defaultSize = track.trex.size
        var defaultFlags = track.trex.flags
        func need(_ n: Int) throws {
            guard q + n <= tfhd.end else { throw TurboMp4Error.malformed("short tfhd fields") }
        }
        if tfhdFlags & 0x1 != 0 {
            try need(8)
            base = turboU64(b, q)
            guard base < (1 << 53) else { throw TurboMp4Error.malformed("base data offset out of range") }
            q += 8
        } else if tfhdFlags & 0x2_0000 != 0 {
            base = moofOffset
        } else {
            base = previousTrafEnd ?? moofOffset
        }
        if tfhdFlags & 0x2 != 0 { try need(4); q += 4 }
        if tfhdFlags & 0x8 != 0 { try need(4); defaultDuration = turboU32(b, q); q += 4 }
        if tfhdFlags & 0x10 != 0 { try need(4); defaultSize = turboU32(b, q); q += 4 }
        if tfhdFlags & 0x20 != 0 { try need(4); defaultFlags = turboU32(b, q); q += 4 }
        guard trackId == track.trackId else { continue }

        if let tfdt = children.first(where: { $0.type == "tfdt" }), !haveTfdt {
            guard tfdt.size >= tfdt.headerSize + 8 else { throw TurboMp4Error.malformed("short tfdt") }
            let version = b[tfdt.payload]
            guard tfdt.size >= tfdt.headerSize + (version == 1 ? 12 : 8) else {
                throw TurboMp4Error.malformed("short tfdt")
            }
            fragment.baseDecodeTime = version == 1
                ? turboU64(b, tfdt.payload + 4)
                : UInt64(turboU32(b, tfdt.payload + 4))
            haveTfdt = true
        }

        var cursor = base
        for trun in children where trun.type == "trun" {
            guard trun.size >= trun.headerSize + 8 else { throw TurboMp4Error.malformed("short trun") }
            let version = b[trun.payload]
            let flags = turboU32(b, trun.payload) & 0x00FF_FFFF
            let count = Int(turboU32(b, trun.payload + 4))
            // A 5 s fragment holds at most a few hundred samples.
            guard count <= 200_000 else { throw TurboMp4Error.malformed("implausible sample count") }
            var p = trun.payload + 8
            let optional = (flags & 0x1 != 0 ? 4 : 0) + (flags & 0x4 != 0 ? 4 : 0)
            guard p + optional <= trun.end else { throw TurboMp4Error.malformed("short trun header") }
            if flags & 0x1 != 0 {
                let offset = Int64(Int32(bitPattern: turboU32(b, p)))
                p += 4
                let start = Int64(base) + offset
                guard start >= 0 else { throw TurboMp4Error.malformed("negative data offset") }
                cursor = UInt64(start)
            }
            var firstFlags: UInt32?
            if flags & 0x4 != 0 {
                firstFlags = turboU32(b, p)
                p += 4
            }
            let fieldCount = [0x100, 0x200, 0x400, 0x800].filter { flags & UInt32($0) != 0 }.count
            guard count >= 0, p + count * fieldCount * 4 <= trun.end else {
                throw TurboMp4Error.malformed("short trun")
            }
            let chunkStart = cursor
            for i in 0 ..< count {
                var duration = defaultDuration
                var size = defaultSize
                var sampleFlags = (i == 0 ? firstFlags : nil) ?? defaultFlags
                var cto: Int32 = 0
                if flags & 0x100 != 0 { duration = turboU32(b, p); p += 4 }
                if flags & 0x200 != 0 { size = turboU32(b, p); p += 4 }
                if flags & 0x400 != 0 { sampleFlags = turboU32(b, p); p += 4 }
                if flags & 0x800 != 0 {
                    let raw = turboU32(b, p)
                    cto = version == 0 ? Int32(clamping: Int64(raw)) : Int32(bitPattern: raw)
                    p += 4
                }
                fragment.durations.append(duration)
                fragment.sizes.append(size)
                fragment.sync.append(sampleFlags & sampleIsNonSync == 0)
                fragment.ctos.append(cto)
                cursor &+= UInt64(size)
            }
            if count > 0 {
                fragment.chunks.append((chunkStart, count))
            }
        }
        previousTrafEnd = cursor
    }
    guard haveTfdt else { throw TurboMp4Error.unsupported("moof without tfdt") }
    guard fragment.sampleCount > 0 else { throw TurboMp4Error.malformed("empty fragment") }
    return fragment
}

// MARK: - Movie builder

/// A contiguous run of fragments of one track, as it appears in the source.
struct TurboTrackWindow {
    let track: TurboTrackInit
    let fragments: [TurboFragment]
    /// Source byte range [regionStart, regionEnd) copied into the virtual mdat.
    let regionStart: UInt64
    let regionEnd: UInt64
    /// elst media_time to write, in media timescale.
    let mediaTime: Int64
    /// How much to present, in media timescale.
    let presentDuration: UInt64
}

struct TurboMovie {
    struct Region {
        let source: Int  // 0 = video, 1 = audio
        let sourceOffset: UInt64
        let length: UInt64
    }

    /// ftyp + moov + mdat header; the regions follow it back to back.
    let header: [UInt8]
    let regions: [Region]

    var totalLength: UInt64 {
        UInt64(header.count) + regions.reduce(0) { $0 + $1.length }
    }
}

private struct TurboWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xFF)) }
    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v >> 24)); bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF)); bytes.append(UInt8(v & 0xFF))
    }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func fourcc(_ s: String) { bytes.append(contentsOf: Array(s.utf8.prefix(4))) }
    mutating func append(_ other: [UInt8]) { bytes.append(contentsOf: other) }
    mutating func append(_ b: [UInt8], _ box: TurboBox) { bytes.append(contentsOf: b[box.offset ..< box.end]) }

    mutating func box(_ type: String, _ body: (inout TurboWriter) throws -> Void) rethrows {
        let start = bytes.count
        u32(0)
        fourcc(type)
        try body(&self)
        let size = UInt32(bytes.count - start)
        bytes[start] = UInt8(size >> 24)
        bytes[start + 1] = UInt8((size >> 16) & 0xFF)
        bytes[start + 2] = UInt8((size >> 8) & 0xFF)
        bytes[start + 3] = UInt8(size & 0xFF)
    }

    mutating func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: (inout TurboWriter) throws -> Void) rethrows {
        try box(type) { w in
            w.u8(version)
            w.u8(UInt8((flags >> 16) & 0xFF)); w.u8(UInt8((flags >> 8) & 0xFF)); w.u8(UInt8(flags & 0xFF))
            try body(&w)
        }
    }
}

private let movieTimescale: UInt32 = 1000

private func toMovieTime(_ value: UInt64, _ timescale: UInt32) -> UInt64 {
    value * UInt64(movieTimescale) / UInt64(timescale)
}

/// Builds the virtual movie for a video window and an optional audio window.
func turboBuildMovie(video: TurboTrackWindow, audio: TurboTrackWindow?) throws -> TurboMovie {
    let windows = [video] + (audio.map { [$0] } ?? [])
    var regionBase: [UInt64] = []
    var running: UInt64 = 0
    for w in windows {
        guard w.regionEnd > w.regionStart else { throw TurboMp4Error.malformed("empty region") }
        guard !w.fragments.isEmpty else { throw TurboMp4Error.malformed("no fragments") }
        // Every sample must lie inside the copied region, or the virtual
        // offsets would point at the wrong bytes.
        for f in w.fragments {
            var sample = 0
            for chunk in f.chunks {
                var bytes: UInt64 = 0
                for i in sample ..< sample + chunk.count { bytes += UInt64(f.sizes[i]) }
                sample += chunk.count
                guard chunk.offset >= w.regionStart, chunk.offset + bytes <= w.regionEnd else {
                    throw TurboMp4Error.malformed("sample data outside region")
                }
            }
        }
        regionBase.append(running)
        running += w.regionEnd - w.regionStart
    }
    let movieDuration = windows
        .map { toMovieTime($0.presentDuration, $0.track.timescale) }
        .max() ?? 0

    func build(headerSize: UInt64) throws -> [UInt8] {
        var w = TurboWriter()
        w.box("ftyp") { w in
            w.fourcc("isom"); w.u32(0x200)
            for brand in ["isom", "iso2", "iso6", "mp41"] { w.fourcc(brand) }
        }
        try w.box("moov") { w in
            w.fullBox("mvhd", version: 0, flags: 0) { w in
                w.u32(0); w.u32(0)  // creation / modification
                w.u32(movieTimescale)
                w.u32(UInt32(clamping: movieDuration))
                w.u32(0x0001_0000)  // rate 1.0
                w.u16(0x0100)  // volume 1.0
                w.u16(0); w.u32(0); w.u32(0)  // reserved
                for v: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { w.u32(v) }
                for _ in 0 ..< 6 { w.u32(0) }  // pre_defined
                w.u32(UInt32(windows.count + 1))  // next_track_ID
            }
            for (index, window) in windows.enumerated() {
                try writeTrak(
                    &w,
                    window: window,
                    trackId: UInt32(index + 1),
                    dataBase: headerSize + regionBase[index]
                )
            }
        }
        // Large-size mdat header covering every region.
        w.u32(1)
        w.fourcc("mdat")
        w.u64(16 + running)
        return w.bytes
    }

    // co64 entries are fixed width, so the header size does not depend on
    // the offsets written into it: measure once, then build for real.
    let probe = try build(headerSize: 0)
    let header = try build(headerSize: UInt64(probe.count))
    guard header.count == probe.count else { throw TurboMp4Error.malformed("header size changed") }
    let regions = windows.enumerated().map { index, w in
        TurboMovie.Region(source: index, sourceOffset: w.regionStart, length: w.regionEnd - w.regionStart)
    }
    return TurboMovie(header: header, regions: regions)
}

private func writeTrak(
    _ w: inout TurboWriter,
    window: TurboTrackWindow,
    trackId: UInt32,
    dataBase: UInt64
) throws {
    let t = window.track
    let b = t.bytes
    let mediaDuration = window.fragments.reduce(UInt64(0)) { $0 + $1.duration }
    let presentMovie = toMovieTime(window.presentDuration, t.timescale)

    try w.box("trak") { w in
        // tkhd: copy, patch track_ID / duration, force enabled+in movie.
        var tkhd = Array(b[t.tkhd.offset ..< t.tkhd.end])
        let p = t.tkhd.headerSize
        let version = tkhd[p]
        tkhd[p + 3] |= 0x03
        let idOffset = p + (version == 1 ? 20 : 12)
        let durationOffset = p + (version == 1 ? 28 : 20)
        guard durationOffset + (version == 1 ? 8 : 4) <= tkhd.count else {
            throw TurboMp4Error.malformed("short tkhd")
        }
        tkhd.replaceSubrange(idOffset ..< idOffset + 4, with: bigEndian(UInt64(trackId), 4))
        if version == 1 {
            tkhd.replaceSubrange(durationOffset ..< durationOffset + 8, with: bigEndian(presentMovie, 8))
        } else {
            tkhd.replaceSubrange(durationOffset ..< durationOffset + 4, with: bigEndian(min(presentMovie, 0xFFFF_FFFF), 4))
        }
        w.append(tkhd)

        w.box("edts") { w in
            w.fullBox("elst", version: 1, flags: 0) { w in
                w.u32(1)
                w.u64(presentMovie)
                w.u64(UInt64(bitPattern: window.mediaTime))
                w.u16(1); w.u16(0)  // media_rate 1.0
            }
        }

        try w.box("mdia") { w in
            var mdhd = Array(b[t.mdhd.offset ..< t.mdhd.end])
            let mp = t.mdhd.headerSize
            let mdhdVersion = mdhd[mp]
            let mdOffset = mp + (mdhdVersion == 1 ? 24 : 16)
            guard mdOffset + (mdhdVersion == 1 ? 8 : 4) <= mdhd.count else {
                throw TurboMp4Error.malformed("short mdhd")
            }
            if mdhdVersion == 1 {
                mdhd.replaceSubrange(mdOffset ..< mdOffset + 8, with: bigEndian(mediaDuration, 8))
            } else {
                guard mediaDuration <= 0xFFFF_FFFF else { throw TurboMp4Error.unsupported("duration overflow") }
                mdhd.replaceSubrange(mdOffset ..< mdOffset + 4, with: bigEndian(mediaDuration, 4))
            }
            w.append(mdhd)
            w.append(b, t.hdlr)
            w.box("minf") { w in
                for child in t.minfChildren { w.append(b, child) }
                w.box("stbl") { w in
                    w.append(b, t.stsd)
                    writeSampleTables(&w, window: window, dataBase: dataBase)
                }
            }
        }
    }
}

private func bigEndian(_ value: UInt64, _ width: Int) -> [UInt8] {
    (0 ..< width).map { UInt8((value >> (8 * UInt64(width - 1 - $0))) & 0xFF) }
}

private func writeSampleTables(_ w: inout TurboWriter, window: TurboTrackWindow, dataBase: UInt64) {
    let fragments = window.fragments

    // stts: run-length decode deltas.
    var stts: [(UInt32, UInt32)] = []
    for f in fragments {
        for d in f.durations {
            if let last = stts.last, last.1 == d {
                stts[stts.count - 1].0 += 1
            } else {
                stts.append((1, d))
            }
        }
    }
    w.fullBox("stts", version: 0, flags: 0) { w in
        w.u32(UInt32(stts.count))
        for (count, delta) in stts { w.u32(count); w.u32(delta) }
    }

    // ctts: composition offsets, signed (version 1) when any is negative.
    let hasCto = fragments.contains { $0.ctos.contains { $0 != 0 } }
    if hasCto {
        var ctts: [(UInt32, Int32)] = []
        var negative = false
        for f in fragments {
            for c in f.ctos {
                if c < 0 { negative = true }
                if let last = ctts.last, last.1 == c {
                    ctts[ctts.count - 1].0 += 1
                } else {
                    ctts.append((1, c))
                }
            }
        }
        w.fullBox("ctts", version: negative ? 1 : 0, flags: 0) { w in
            w.u32(UInt32(ctts.count))
            for (count, offset) in ctts { w.u32(count); w.u32(UInt32(bitPattern: offset)) }
        }
    }

    // stss: omitted when every sample is a sync sample (audio).
    let allSync = fragments.allSatisfy { $0.sync.allSatisfy { $0 } }
    if !allSync {
        var syncSamples: [UInt32] = []
        var number: UInt32 = 1
        for f in fragments {
            for s in f.sync {
                if s { syncSamples.append(number) }
                number += 1
            }
        }
        w.fullBox("stss", version: 0, flags: 0) { w in
            w.u32(UInt32(syncSamples.count))
            for n in syncSamples { w.u32(n) }
        }
    }

    // stsz
    let sampleCount = fragments.reduce(0) { $0 + $1.sampleCount }
    w.fullBox("stsz", version: 0, flags: 0) { w in
        w.u32(0)
        w.u32(UInt32(sampleCount))
        for f in fragments { for s in f.sizes { w.u32(s) } }
    }

    // stsc + co64: one chunk per trun.
    var chunks: [(offset: UInt64, count: Int)] = []
    for f in fragments { chunks.append(contentsOf: f.chunks) }
    var stsc: [(UInt32, UInt32)] = []
    for (index, chunk) in chunks.enumerated() where stsc.last?.1 != UInt32(chunk.count) {
        stsc.append((UInt32(index + 1), UInt32(chunk.count)))
    }
    w.fullBox("stsc", version: 0, flags: 0) { w in
        w.u32(UInt32(stsc.count))
        for (first, perChunk) in stsc { w.u32(first); w.u32(perChunk); w.u32(1) }
    }
    w.fullBox("co64", version: 0, flags: 0) { w in
        w.u32(UInt32(chunks.count))
        for chunk in chunks { w.u64(dataBase + (chunk.offset - window.regionStart)) }
    }
}
