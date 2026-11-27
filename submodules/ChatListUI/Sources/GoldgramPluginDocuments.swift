import Foundation
import UIKit
import UniformTypeIdentifiers
import PDFKit
import Compression

// A bounded reader for the main text part of a conventional ZIP-based DOCX.
// No archive extraction, filesystem writes, external XML entities or links.
enum GoldgramDocumentReader {
    enum Failure: Error { case invalid, unsupported, tooLarge, noText }
    static let maxInput = 8 * 1024 * 1024
    static let maxXML = 512 * 1024
    static let maxText = 48000
    private static func u16(_ data: Data, _ i: Int) -> Int {
        Int(data[i]) | Int(data[i+1]) << 8
    }
    private static func u32(_ data: Data, _ i: Int) -> Int {
        u16(data, i) | u16(data, i+2) << 16
    }
    private static func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 1 ? 0xedb88320 : 0) }
        }
        return value ^ 0xffffffff
    }
    static func mainXML(_ data: Data) throws -> Data {
        guard data.count >= 22, data.count <= maxInput else { throw Failure.invalid }
        var end: Int?
        for i in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if u32(data,i) == 0x06054b50, i + 22 + u16(data,i+20) == data.count { end = i; break }
        }
        guard let e = end, u16(data,e+4) == 0, u16(data,e+6) == 0,
              u16(data,e+8) == u16(data,e+10) else { throw Failure.unsupported }
        let count = u16(data,e+10), size = u32(data,e+12), start = u32(data,e+16)
        guard (1...1024).contains(count), start <= e, size == e-start else { throw Failure.invalid }
        var p = start; var answer: Data?
        let target = Data("word/document.xml".utf8)
        for _ in 0..<count {
            guard p <= e-46, u32(data,p) == 0x02014b50 else { throw Failure.invalid }
            let flags = u16(data,p+8), method = u16(data,p+10), checksum = u32(data,p+16)
            let compressed = u32(data,p+20), plain = u32(data,p+24)
            let n = u16(data,p+28), x = u16(data,p+30), comment = u16(data,p+32), offset = u32(data,p+42)
            let next = p+46+n+x+comment
            guard next <= e, u16(data,p+34) == 0 else { throw Failure.invalid }
            if data.subdata(in: p+46..<p+46+n) == target {
                guard answer == nil, flags & ~0x080e == 0, (method == 0 || method == 8),
                      plain > 0, plain <= maxXML, compressed > 0, compressed <= maxInput,
                      offset <= start-30, u32(data,offset) == 0x04034b50,
                      u16(data,offset+6) == flags, u16(data,offset+8) == method else { throw Failure.unsupported }
                let localN = u16(data,offset+26), localX = u16(data,offset+28)
                let content = offset+30+localN+localX
                guard content <= start, compressed <= start-content,
                      data.subdata(in: offset+30..<offset+30+localN) == target else { throw Failure.invalid }
                let zipped = data.subdata(in: content..<content+compressed)
                let decoded: Data
                if method == 0 {
                    guard compressed == plain else { throw Failure.invalid }; decoded = zipped
                } else {
                    var bytes = Data(count: plain+1)
                    let length = bytes.withUnsafeMutableBytes { output in
                        zipped.withUnsafeBytes { input in
                            compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, plain+1,
                                input.bindMemory(to: UInt8.self).baseAddress!, compressed, nil, COMPRESSION_ZLIB)
                        }
                    }
                    guard length == plain else { throw Failure.invalid }
                    decoded = bytes.prefix(plain)
                }
                guard crc(decoded) == UInt32(checksum) else { throw Failure.invalid }
                answer = decoded
            }
            p = next
        }
        guard p == e, let answer else { throw Failure.invalid }
        return answer
    }
    private final class WordText: NSObject, XMLParserDelegate {
        var output = ""; var body = 0; var text = 0
        private func word(_ uri: String?) -> Bool {
            uri == "http://schemas.openxmlformats.org/wordprocessingml/2006/main" ||
            uri == "http://purl.oclc.org/ooxml/wordprocessingml/main"
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String]) {
            guard word(namespaceURI) else { return }
            if elementName == "body" { body += 1 }
            if body > 0 {
                if elementName == "t" { text += 1 }
                if elementName == "tab" { output += "\t" }
                if elementName == "br" { output += "\n" }
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if body > 0, text > 0 { output += string } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard word(namespaceURI) else { return }
            if body > 0, elementName == "p" { output += "\n" }
            if elementName == "t" { text = max(0,text-1) }
            if elementName == "body" { body = max(0,body-1) }
        }
    }
    static func docx(_ data: Data) throws -> String {
        let xml = try mainXML(data)
        guard let decoded = String(data: xml, encoding: .utf8), !decoded.contains("\0"),
              !decoded.contains("<!DOCTYPE"), !decoded.contains("<!ENTITY") else { throw Failure.unsupported }
        let parser = XMLParser(data: xml); let reader = WordText()
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse() else { throw Failure.invalid }
        return reader.output
    }
    private static func bounded(_ text: String) -> (String, Bool) {
        if text.utf8.count <= maxText { return (text, false) }
        var result = ""; var size = 0
        for ch in text {
            let n = String(ch).utf8.count
            if size + n > maxText { break }
            size += n; result.append(ch)
        }
        return (result, true)
    }
    static func read(_ data: Data, name: String, ext: String) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maxInput else { throw Failure.tooLarge }
        var text = ""; var partial = false; var pages = 0
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw Failure.invalid }
            pages = pdf.pageCount
            for i in 0..<min(pages,20) {
                let pageText = pdf.page(at:i)?.string ?? ""
                let (joined, cut) = bounded(text + (i == 0 ? "" : "\n\n") + pageText)
                text = joined
                if cut { partial = true; break }
            }
            partial = partial || pages > 20
        case "docx": text = try docx(data)
        case "txt", "json":
            guard let decoded = String(data:data,encoding:.utf8), !decoded.contains("\0") else { throw Failure.invalid }
            if ext == "json" { guard (try? JSONSerialization.jsonObject(with:data,options:[.fragmentsAllowed])) != nil else { throw Failure.invalid } }
            text = decoded
        default: throw Failure.unsupported
        }
        let (out, cut) = bounded(text)
        guard !out.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw Failure.noText }
        return ["name":String(name.prefix(160)), "format":ext, "text":out, "bytes":data.count, "pageCount":pages, "truncated":partial || cut]
    }
}

@MainActor
final class GoldgramPluginDocumentSession: NSObject, UIDocumentPickerDelegate {
    private weak var presenter: UIViewController?
    private let valid: () -> Bool
    private var picker: UIDocumentPickerViewController?
    private var reply: (([String: Any]) -> Void)?
    private var used = false
    var busy: Bool { reply != nil }
    init(presenter: UIViewController, valid: @escaping () -> Bool) {
        self.presenter = presenter; self.valid = valid
    }
    func pick(completion: @escaping ([String: Any]) -> Void) {
        guard !used, !busy, valid(), UIApplication.shared.applicationState == .active else { completion(["error":"Выбор документа недоступен."]); return }
        used = true; reply = completion
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35) { [weak self] in
            guard let self, self.busy else { return }
            guard self.valid(), let presenter = self.presenter, presenter.viewIfLoaded?.window != nil,
                  presenter.presentedViewController == nil else { self.finish(["error":"Контекст изменился."]); return }
            var types: [UTType] = [.pdf, .plainText, .json]
            if let word = UTType(filenameExtension:"docx") { types.append(word) }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes:types, asCopy:true)
            picker.delegate = self; picker.allowsMultipleSelection = false; picker.modalPresentationStyle = .formSheet
            self.picker = picker; presenter.present(picker,animated:true)
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(["value":NSNull()]) }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls:[URL]) {
        guard busy, valid(), let url = urls.first else { finish(["error":"Контекст изменился."]); return }
        picker = nil
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let answer: [String: Any]
            do {
                let meta = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
                guard meta.isRegularFile == true, let size = meta.fileSize, size > 0, size <= GoldgramDocumentReader.maxInput else { throw GoldgramDocumentReader.Failure.tooLarge }
                let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
                let data = try handle.read(upToCount:GoldgramDocumentReader.maxInput+1) ?? Data()
                let result = try GoldgramDocumentReader.read(data,name:url.lastPathComponent,ext:url.pathExtension.lowercased())
                answer = ["value":result]
            } catch GoldgramDocumentReader.Failure.noText {
                answer = ["error":"Текст не найден. Для сканированного PDF требуется OCR."]
            } catch {
                answer = ["error":"Не удалось прочитать документ. Проверьте формат, пароль и лимит 8 МБ."]
            }
            DispatchQueue.main.async { [weak self = self] in
                guard let self, self.busy else { return }
                guard self.valid(), UIApplication.shared.applicationState == .active else { self.finish(["error":"Контекст изменился."]); return }
                self.finish(answer)
            }
        }
    }
    private func finish(_ result:[String:Any]) {
        let done = reply; reply = nil; picker = nil
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35) { done?(result) }
    }
    func cancel() {
        reply = nil
        if let picker, picker.presentingViewController != nil { picker.dismiss(animated:false) }
        picker = nil
    }
}
