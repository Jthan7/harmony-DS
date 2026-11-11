export enum MessageRole {
  User = 0,
  Assistant = 1
}

export enum MessageStatus {
  Streaming = 0,
  Done = 1,
  Error = 2
}

export interface SessionSummary {
  id: string;
  title: string;
  updatedAtMs: number;
  pinned: boolean;
}

@ObservedV2
export class ChatMessage {
  @Trace id: string;
  @Trace role: MessageRole;
  @Trace content: string;
  @Trace thinking: string;
  @Trace status: MessageStatus;
  @Trace thinkingElapsedMs: number;
  @Trace errorMsg: string;
  @Trace serverMessageId: number;
  @Trace attachmentNames: string[];
  /** 联网搜索结果（SSE SEARCH fragment 捕获），供 [reference:N]/[citation:N] 角标解析 */
  @Trace searchResults: SearchResultInfo[];
  /** 联网搜索进行中（SEARCH fragment 到达置 true，思考/回答片段到达或流结束置 false） */
  @Trace searching: boolean;
  /** 搜索过程提示（SEARCH fragment 的 content，如查询状态文本，可为空） */
  @Trace searchHint: string;
  readonly createTimeMs: number;

  constructor(id: string, role: MessageRole, content: string) {
    this.id = id;
    this.role = role;
    this.content = content;
    this.thinking = '';
    this.status = MessageStatus.Done;
    this.thinkingElapsedMs = 0;
    this.errorMsg = '';
    this.serverMessageId = 0;
    this.attachmentNames = [];
    this.searchResults = [];
    this.searching = false;
    this.searchHint = '';
    this.createTimeMs = Date.now();
  }
}

/** 联网搜索结果条目（服务端 SEARCH fragment 的 results 数组元素） */
@ObservedV2
export class SearchResultInfo {
  url: string;
  title: string;
  snippet: string;
  /** 服务端 cite_index（通常 0-based，与 [reference:N] 的 N 对应） */
  citeIndex: number;
  siteName: string;
  publishedAt: string;

  constructor(url: string, title: string, snippet: string, citeIndex: number,
    siteName: string, publishedAt: string) {
    this.url = url;
    this.title = title;
    this.snippet = snippet;
    this.citeIndex = citeIndex;
    this.siteName = siteName;
    this.publishedAt = publishedAt;
  }
}

/** 附件上传状态：上传中 → 解析中 → 就绪 / 失败 */
export enum AttachmentStatus {
  Uploading = 0,
  Parsing = 1,
  Ready = 2,
  Failed = 3
}

/** 待发送附件（对应服务端 /api/v0/file/upload_file 的文件对象） */
@ObservedV2
export class ChatAttachment {
  /** 本地唯一标识（与服务端 fileId 无关，用于列表 key 与移除） */
  readonly localId: string;
  @Trace fileId: string;
  @Trace fileName: string;
  @Trace fileSize: number;
  @Trace status: AttachmentStatus;
  /** 上传百分比 0-100 */
  @Trace percent: number;
  @Trace errorMsg: string;

  constructor(localId: string, fileName: string, fileSize: number) {
    this.localId = localId;
    this.fileId = '';
    this.fileName = fileName;
    this.fileSize = fileSize;
    this.status = AttachmentStatus.Uploading;
    this.percent = 0;
    this.errorMsg = '';
  }
}
