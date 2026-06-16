# ── 构建阶段 ──────────────────────────────────────────────────────────────────
# 使用 BUILDPLATFORM 加速跨平台构建（在 x86 宿主机上执行 yarn install / node-gyp）
FROM --platform=$BUILDPLATFORM node:18-alpine AS builder

WORKDIR /home

# 先复制依赖清单，充分利用 Docker 层缓存
COPY package.json yarn.lock ./

# 安装构建工具链（armv7 下 better-sqlite3 需要原生编译）
# 安装 python3、make、g++ 用于 node-gyp 编译，编译后立即清理
RUN apk add --no-cache python3 make g++ \
    && yarn install --ignore-engines \
    && apk del python3 make g++ \
    && rm -rf /var/cache/apk/*

# 复制源码并编译
COPY . .
# 清理 vender 内非运行时目录
RUN rm -rf vender/cloud189-sdk/docs vender/cloud189-sdk/example \
           vender/cloud189-sdk/test vender/cloud189-sdk/.git \
           vender/cloud189-sdk/.vscode vender/cloud189-sdk/.github
# 复制第三方前端组件到 public/vendor
RUN node scripts/copy-vendor.js && npx tsc && cp -r src/public dist/public
# 删除 vendor 内的 source map
RUN find dist/public/vendor -name "*.js.map" -delete 2>/dev/null; true

# 原地裁剪 node_modules 为纯生产依赖
RUN yarn install --production --ignore-engines && \
    yarn cache clean && \
    find node_modules -name "*.d.ts" -delete && \
    find node_modules -name "*.d.ts.map" -delete && \
    find node_modules -name "*.js.map" -delete && \
    rm -rf node_modules/typeorm/browser && \
    find node_modules \( -name "README*" -o -name "CHANGELOG*" \) -not -path "*/bin/*" -delete 2>/dev/null; true

# ── 生产阶段 ──────────────────────────────────────────────────────────────────
# 生产阶段使用目标平台架构（arm/v7）
FROM node:18-alpine AS production

WORKDIR /home

ARG APP_VERSION=dev

# 安装系统运行时包、设置时区、创建持久化目录
RUN apk add --no-cache ca-certificates tzdata && \
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone && \
    mkdir -p /home/data /home/strm && \
    chown -R node:node /home

# 复制 Builder 中已裁剪的 node_modules（同为 Alpine，原生库兼容）
COPY --from=builder /home/node_modules ./node_modules
COPY --from=builder /home/dist ./dist
# 兜底：显式复制前端静态资源
COPY --from=builder /home/src/public ./dist/public
COPY --from=builder /home/package.json ./

ENV TZ=Asia/Shanghai
ENV NODE_ENV=production
ENV APP_VERSION=${APP_VERSION}

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -qO- http://127.0.0.1:3000/api/health || exit 1

USER node

VOLUME ["/home/data", "/home/strm"]
EXPOSE 3000
CMD ["npm", "run", "start:prod"]
