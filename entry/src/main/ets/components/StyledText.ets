import { MdSpan } from './MarkdownParser';
import { buildInlineStyled, MdTextColorKind } from './MdInlineBuilder';
import { SearchResultInfo } from '../model/ChatModels';

/**
 * 通用富文本组件：MdSpan[] → TextController 绑定 MutableStyledString。
 * 链接点击通过 GestureStyle 生效（Span 组件触摸事件不生效，见 faqs-arkui-888/1337）。
 * GestureStyle 回调对象随组件持有的 MutableStyledString 成员存活，避免提前回收（faqs-arkui-901）。
 */
@ComponentV2
export struct StyledText {
  @Param spans: MdSpan[] = [];
  @Param fontSize: number = 18;
  @Param lineHeight: number = 30;
  @Param colorKind: number = MdTextColorKind.Primary;
  @Param boldWeight: number = 400;
  @Param searchResults: SearchResultInfo[] = [];
  @Event onLinkClick: (url: string) => void = (): void => {
  };
  @Event onReferenceClick: (url: string, title: string) => void = (_url: string, _title: string): void => {
  };

  private textController: TextController = new TextController();
  private styledContent: MutableStyledString | null = null;

  aboutToAppear(): void {
    this.applyStyledString();
  }

  @Monitor('spans', 'fontSize', 'colorKind', 'searchResults')
  onStyledParamsChange(): void {
    this.applyStyledString();
  }

  private applyStyledString(): void {
    this.styledContent = buildInlineStyled(this.spans, this.fontSize, this.colorKind,
      (url: string): void => {
        this.onLinkClick(url);
      },
      this.searchResults,
      (url: string, title: string): void => {
        this.onReferenceClick(url, title);
      });
    this.textController.setStyledString(this.styledContent);
  }

  build() {
    Text(undefined, { controller: this.textController })
      .fontSize(this.fontSize)
      .lineHeight(this.lineHeight)
      .fontWeight(this.boldWeight)
      .width('100%')
      // 长按选择文字并复制（系统选择菜单）
      .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
      .copyOption(CopyOptions.LocalDevice)
  }
}
