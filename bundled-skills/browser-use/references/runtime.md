# Browser Docker Use references

## Purpose

这个 skill 用于在**Docker + Xvfb + headful Chromium** 环境中执行浏览器任务，强调：
- 常驻浏览器
- 低内存占用
- profile 隔离
- 1920x1080 固定分辨率
- 可与 CDP 联合使用
- 登录类任务需要及时向用户索要凭据/验证码/手机号

## Local project

项目位置：
- `/root/.paco/docker-browser-use`

默认服务：
- API: `http://127.0.0.1:8080`
- VNC: `127.0.0.1:5900`

默认浏览器：
- Chromium
- headful
- Xvfb
- 1920x1080

## Interaction model

推荐流程：
1. 先启动或复用某个 `profile_id`
2. 在该 profile 下继续浏览器操作
3. 不同账号使用不同 profile
4. 不要主动退出账号
5. 如遇登录页且缺少凭据，立即向用户索要

## API endpoints in local service

- `GET /healthz`
- `POST /session/start`
- `GET /session/list`
- `GET /session/{profile_id}`
- `POST /browser/navigate`
- `POST /browser/type`
- `POST /browser/screenshot`
- `POST /agent/run`

## Limits / next-step note

当前基础代码已经完成：
- 容器
- Xvfb
- Chromium
- persistent profiles
- screenshot
- navigation
- user-input escalation

如果要进一步增强，可继续补：
- 真正把 browser-use `Agent(...)` 接进 `/agent/run`
- CDP endpoint 精确暴露
- 更细的页面动作 API（click/select/fill/state）
- 登录态状态检测
