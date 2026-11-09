# 官网

单页静态站，零构建、零依赖、零外链资源（字体走系统字族，图标是内联 SVG）。

```
site/
├── index.html    # 全部内容与样式都在这一个文件里
├── favicon.svg
└── _headers      # Cloudflare Pages 的响应头
```

## 部署到 Cloudflare Pages

Pages → Create project → Connect to Git，然后：

| 设置项 | 值 |
|---|---|
| Framework preset | None |
| Build command | *（留空）* |
| Build output directory | `site` |
| Root directory | *（留空，即仓库根）* |

push 到 `main` 即自动部署。自定义域在 Pages 项目的 Custom domains 里绑。

## 改内容

`index.html` 顶部是全部设计令牌（颜色、阴影），浅色与深色各一套，跟随访问者的系统设置。
文案与结构都在同一个文件里，直接改。

## 上线前要替换的占位

| 位置 | 现在的值 | 说明 |
|---|---|---|
| App Store 链接（3 处） | `https://apps.apple.com/app/baobox/id000000000` | 上架后换成真实 ID |
| 价格（2 处） | `¥98` | 定价确定后统一替换 |
| 域名 | `https://baobox.app/` | `canonical` 与 `og:url` |
| 客服邮箱 | `support@baobox.app` | 页脚 |
| 隐私政策 / 使用条款 | `/privacy`、`/terms` | **App Store 上架必须有隐私政策页**，需另建 |
| 社交预览图 | 无 | 准备 1200×630 PNG 放进 `site/`，再补 `og:image` 与 `twitter:image` |
