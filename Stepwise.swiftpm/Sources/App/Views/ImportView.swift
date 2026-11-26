import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import VisionKit
#endif

struct ImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var material: ImportedMaterial?
    /// 正在后台读选的文件、照片
    @State private var readingID: UUID?
    @State private var pastedText = ""
    @State private var pdfAsImages = false
    /// 程序根据自动判断结果同步开关时，不要触发重新渲染
    @State private var syncingToggle = false
    @State private var requirement = ""
    @State private var title = ""
    /// 放到哪个文件夹；默认是当前打开的题集所在的文件夹
    @State private var folderID: UUID?
    @State private var folderInitialized = false

    @State private var showFilePicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showScanner = false

    @State private var working = false
    @State private var progress = GenerationProgress()
    @State private var task: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showConsent = false

    private static let examples = [L("每个小问单独作为一道题"), L("只要选择题"), L("忽略答案和解析部分"), L("保留原题号")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showFilePicker = true } label: {
                        Label("选择文件（PDF / 图片 / 文本）", systemImage: "folder")
                    }
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 20, matching: .images) {
                        Label("从相册选择图片", systemImage: "photo.on.rectangle")
                    }
                    #if os(iOS)
                    if VNDocumentCameraViewController.isSupported {
                        Button { showScanner = true } label: {
                            Label("扫描纸质题目", systemImage: "doc.viewfinder")
                        }
                    }
                    #endif
                } header: {
                    Text("导入题目")
                }

                if readingID != nil {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取…").foregroundStyle(.secondary)
                        }
                    }
                }
                if let material {
                    Section("已载入") {
                        HStack {
                            Image(systemName: material.images.isEmpty ? "doc.text" : "photo.stack")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(material.name).lineLimit(1)
                                Text(material.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { self.material = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                        if material.pdfData != nil {
                            Toggle(isOn: $pdfAsImages) {
                                VStack(alignment: .leading) {
                                    Text("按图片识别 PDF")
                                    Text("适合扫描件，或含公式、图形的题目；需要支持图片的模型")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .onChange(of: pdfAsImages) {
                                if syncingToggle { syncingToggle = false } else { reloadPDF() }
                            }
                        }
                    }
                } else {
                    Section {
                        TextEditor(text: $pastedText)
                            .frame(minHeight: 140)
                    } header: {
                        Text("或者直接粘贴题目文字")
                    }
                }

                Section {
                    TextField("例如：每个小问单独作为一道题", text: $requirement, axis: .vertical)
                        .lineLimit(1...4)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.examples, id: \.self) { ex in
                                Button(ex) {
                                    requirement = requirement.isEmpty ? ex : requirement + "；" + ex
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("拆分要求（可选）")
                }

                Section("题集名称（可选，不填由 AI 起名）") {
                    TextField("例如：高一数学 第三章练习", text: $title)
                    if !store.folders.isEmpty {
                        Picker("放到文件夹", selection: $folderID) {
                            Text("最外层").tag(UUID?.none)
                            ForEach(store.folderTree(), id: \.folder.id) { item in
                                Text(String(repeating: "    ", count: item.depth) + item.folder.name).tag(Optional(item.folder.id))
                            }
                        }
                        .onAppear {
                            guard !folderInitialized else { return }
                            folderInitialized = true
                            folderID = store.set(store.selectedSetID)?.folderID.flatMap { store.folder($0)?.id }
                        }
                    }
                }

                Section {
                    if working {
                        // 拆分要一会儿：显示大概进度、找到了几道题、用了多久
                        GenerationProgressView(progress: progress, parallel: true) { String(localized: "已识别 \($0) 道题") }
                            .padding(.vertical, 6)
                    } else {
                        Button {
                            start()
                        } label: {
                            HStack {
                                Spacer()
                                Label("开始拆分题目", systemImage: "scissors")
                                    .font(.headline)
                                Spacer()
                            }
                        }
                        .disabled(currentMaterial == nil || readingID != nil)
                    }
                } footer: {
                    if let p = store.activeProvider, let v = store.visionProvider {
                        Text("文字用 \(p.name) · \(p.model.isEmpty ? L("未选择模型") : p.model)；照片、扫描件等图片一律用 \(v.name) · \(v.model) 识别。")
                    } else if let p = store.activeProvider {
                        Text("将使用 \(p.name) · \(p.model.isEmpty ? "未选择模型" : p.model)。图片和扫描件需要支持图片输入的模型。")
                    }
                }
            }
            .navigationTitle("导入题目")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    ModelMenu { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showConsent, onDismiss: {
                // 刚同意就接着开始拆分
                if store.aiConsent == true { start() }
            }) { ConsentView() }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.pdf, .image, .plainText, .text, .rtf, .commaSeparatedText],
                          allowsMultipleSelection: false) { result in
                handleFile(result)
            }
            .onChange(of: photoItems) { loadPhotos() }
            #if os(iOS)
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner { images in
                    showScanner = false
                    if !images.isEmpty {
                        material = ImportedMaterial(name: L("扫描的题目"), images: images)
                    }
                }
                .ignoresSafeArea()
            }
            #endif
        }
        .interactiveDismissDisabled(working)
    }

    private var currentMaterial: ImportedMaterial? {
        if let material, !material.isEmpty { return material }
        let text = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : ImportedMaterial(name: L("粘贴的题目"), textPages: [text])
    }

    // 读文件、把 PDF 一页页画成图、缩小照片都在后台做：以前在主线程上，选了 30 页的 PDF 或一堆照片后界面要卡好几秒
    private func handleFile(_ result: Result<[URL], Error>) {
        let url: URL
        do {
            guard let first = try result.get().first else { return }
            url = first
        } catch {
            store.errorMessage = error.localizedDescription
            return
        }
        readMaterial { try Importer.load(url: url) } then: { loaded in
            material = loaded
            let detected = !loaded.images.isEmpty && loaded.pdfData != nil
            if detected != pdfAsImages {
                syncingToggle = true
                pdfAsImages = detected
            }
        }
    }

    private func reloadPDF() {
        guard let m = material, let data = m.pdfData else { return }
        let mode: Importer.PDFMode = pdfAsImages ? .images : .text
        readMaterial { try Importer.loadPDF(data: data, name: m.name, mode: mode) } then: { material = $0 }
    }

    /// 在后台读材料，读好了回到主线程；后读的覆盖先读的，先读的晚到了就不要
    private func readMaterial(_ work: @escaping @Sendable () throws -> ImportedMaterial,
                              then apply: @escaping (ImportedMaterial) -> Void) {
        readingID = UUID()
        let id = readingID
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            guard readingID == id else { return }
            readingID = nil
            switch result {
            case .success(let loaded): apply(loaded)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
    }

    private func loadPhotos() {
        let items = photoItems
        guard !items.isEmpty else { return }
        readingID = UUID()
        let id = readingID
        Task {
            var images: [Data] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let jpeg = await Task.detached(priority: .userInitiated, operation: { ImageUtil.normalizedJPEG(data) }).value {
                    images.append(jpeg)
                }
            }
            photoItems = []
            guard readingID == id else { return }
            readingID = nil
            if images.isEmpty {
                store.errorMessage = L("没有读取到图片")
            } else {
                material = ImportedMaterial(name: L("相册图片"), images: images)
            }
        }
    }

    private func start() {
        guard let source = currentMaterial else { return }
        // 拆分需要把题目发给 AI，先确认用户已同意
        guard store.aiConsent == true else {
            showConsent = true
            return
        }
        working = true
        progress = GenerationProgress()
        task = Task {
            do {
                var newSet = try await store.split(material: source, requirement: requirement, title: title) { p in
                    progress = p
                }
                newSet.folderID = folderID
                store.addSet(newSet)
                if let folderID { store.setCollapsed(folderID, false) }
                dismiss()
            } catch {
                if !(error is CancellationError) && !(error is ConsentRequired) {
                    store.errorMessage = error.localizedDescription
                }
            }
            working = false
        }
    }
}

#if os(iOS)
/// 系统文档扫描（自动裁边、校正透视）
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([Data]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([Data]) -> Void
        init(onFinish: @escaping ([Data]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).compactMap { i -> Data? in
                guard let cg = scan.imageOfPage(at: i).cgImage else { return nil }
                return ImageUtil.jpeg(cg, maxPixel: 1600)
            }
            onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}
#endif
