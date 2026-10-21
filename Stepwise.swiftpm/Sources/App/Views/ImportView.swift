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
    @State private var pastedText = ""
    @State private var pdfAsImages = false
    /// 程序根据自动判断结果同步开关时，不要触发重新渲染
    @State private var syncingToggle = false
    @State private var requirement = ""
    @State private var title = ""

    @State private var showFilePicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showScanner = false

    @State private var working = false
    @State private var progressText = ""
    @State private var task: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showConsent = false

    private static let examples = ["每个小问单独作为一道题", "只要选择题", "忽略答案和解析部分", "保留原题号"]

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
                }

                Section {
                    Button {
                        start()
                    } label: {
                        HStack {
                            Spacer()
                            if working {
                                ProgressView().padding(.trailing, 6)
                                Text(progressText)
                            } else {
                                Label("开始拆分题目", systemImage: "scissors")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(working || currentMaterial == nil)
                } footer: {
                    if let p = store.activeProvider {
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
                        material = ImportedMaterial(name: "扫描的题目", images: images)
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
        return text.isEmpty ? nil : ImportedMaterial(name: "粘贴的题目", textPages: [text])
    }

    private func handleFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            material = try Importer.load(url: url)
            let detected = !(material?.images.isEmpty ?? true) && material?.pdfData != nil
            if detected != pdfAsImages {
                syncingToggle = true
                pdfAsImages = detected
            }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func reloadPDF() {
        guard let m = material, let data = m.pdfData else { return }
        do {
            material = try Importer.loadPDF(data: data, name: m.name, mode: pdfAsImages ? .images : .text)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func loadPhotos() {
        let items = photoItems
        guard !items.isEmpty else { return }
        Task {
            var images: [Data] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let jpeg = ImageUtil.normalizedJPEG(data) {
                    images.append(jpeg)
                }
            }
            photoItems = []
            if images.isEmpty {
                store.errorMessage = "没有读取到图片"
            } else {
                material = ImportedMaterial(name: "相册图片", images: images)
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
        progressText = "正在拆分…"
        task = Task {
            do {
                let newSet = try await store.split(material: source, requirement: requirement, title: title) { i, n in
                    progressText = n > 1 ? "正在拆分 第 \(i)/\(n) 部分…" : "正在拆分…"
                }
                store.addSet(newSet)
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
                guard let cg = scan.imageOfPage(at: i).cgImage, let jpeg = ImageUtil.jpeg(cg) else { return nil }
                return ImageUtil.normalizedJPEG(jpeg)
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
