# Kingdom Dashboard

Kingdom의 역할, 큐, 이벤트 흐름을 2D 중세 성 맵으로 시각화하는 웹 대시보드.

## 레이아웃

```
+------------------+---------------------------+-----------------+
|  🔭 감시탑       |  👑 왕의 방               |  📯 통신탑      |
|  Sentinel        |  Queue Overview           |  Envoy          |
|  (heartbeat,     |  (이벤트/태스크/진행중    |  (메시지 대기,  |
|   이벤트 배지)   |   카운터)                 |   실패 현황)    |
+------------------+---------------------------+-----------------+
|  🏰 관리실       |  ⚔️ 장군 막사              |  📜 이벤트 로그 |
|  Chamberlain     |  Generals                 |  (최근 10개     |
|  (CPU/MEM/DISK   |  (장군 카드 + 타입 태그)  |   타임라인)     |
|   게이지바)      +---------------------------+                 |
|                  |  🛡️ 훈련장                |                 |
|                  |  Soldiers                 |                 |
|                  |  (활성 병사 + 실시간      |                 |
|                  |   타이머)                 |                 |
+------------------+---------------------------+-----------------+
```

## 캐릭터 시스템

각 역할은 상태에 따라 다른 애니메이션을 보여준다.

| 역할 | 이모지 | idle | active | dead |
|------|--------|------|--------|------|
| 파수꾼 | 🔭 | 바운스 | 좌우 두리번 (이벤트 감지) | 회색 + 💀 |
| 왕 | 👑 | 바운스 | 망치질 (태스크 라우팅) | 회색 + 💀 |
| 사절 | 📯 | 바운스 | 망치질 (메시지 발송) | 회색 + 💀 |
| 내관 | 🏰 | 순찰 이동 | 순찰 이동 | 회색 + 💀 |
| 병사 | 🛡️ | - | 카드 + 실시간 타이머 | - |

**상태 변화 시 아이템 플로팅 애니메이션:**
- 📜 이벤트: 파수꾼 → 왕
- 📋 태스크: 왕 → 장군 막사
- ✉️ 메시지: 사절 → 외부

**생사 판단**: heartbeat 60초 초과 시 캐릭터가 회색으로 변하고 💀 표시.

## 아키텍처

```
bin/dashboard-collect.sh  →  state/dashboard.json  ←  tools/dashboard/index.html
(chamberlain 30초 주기)      (통합 스냅샷)              (5초마다 fetch)
```

### 데이터 흐름

1. **수집**: `bin/dashboard-collect.sh`가 `state/`, `queue/`, `config/generals/`, `logs/`를 읽어 하나의 JSON으로 합침
2. **저장**: `state/dashboard.json`에 atomic write (`.tmp` → `mv`)
3. **서빙**: Docker 컨테이너 (nginx:alpine)가 HTML + JSON을 제공
4. **렌더링**: 브라우저가 5초마다 fetch → 이전 상태와 diff → 변경분만 애니메이션

### dashboard.json 구조

```json
{
  "collected_at": "2026-03-05T10:00:00Z",
  "system": {
    "health": "green",
    "cpu_percent": 45.0,
    "memory_percent": 60.0,
    "disk_percent": 35,
    "load_avg": "1.2,0.8,0.6"
  },
  "roles": {
    "king": { "alive": true, "heartbeat_age_s": 12 },
    "sentinel": { "alive": true, "heartbeat_age_s": 8 },
    "envoy": { "alive": true, "heartbeat_age_s": 15 },
    "chamberlain": { "alive": true, "heartbeat_age_s": 5 }
  },
  "generals": [
    { "name": "gen-pr", "description": "...", "type": "event" }
  ],
  "queue": {
    "events_pending": 2,
    "tasks_pending": 1,
    "tasks_active": 3,
    "messages_pending": 0,
    "messages_failed": 0
  },
  "soldiers": [
    { "task_id": "task-001", "general": "gen-pr", "started_at": "...", "elapsed_s": 120 }
  ],
  "recent_events": [
    { "type": "github.pr.review_requested", "ts": "..." }
  ]
}
```

## 실행 방법

### Docker (운영)

```bash
# 이미지 빌드
docker build -t kingdom-dashboard .

# 실행 (state/dashboard.json을 read-only 마운트)
docker run -d --name kingdom-dashboard \
  -p 9000:9000 \
  -v /opt/kingdom/state/dashboard.json:/data/dashboard.json:ro \
  --restart unless-stopped \
  kingdom-dashboard

# 접속
open http://localhost:9000
```

> `setup.sh`가 이미지를 빌드하고, `start.sh`/`stop.sh`가 컨테이너를 자동 관리한다.

### Docker Compose

```bash
docker compose up -d --build
```

### 로컬 개발 (Python)

```bash
# 프로젝트 루트에서
python3 -m http.server 8888

# 접속
open http://localhost:8888/tools/dashboard/index.html
```

> 개발 모드에서는 `state/dashboard.json`이 없으면 데모 데이터로 자동 폴백한다.

## 파일 구조

```
tools/dashboard/
├── index.html          # 대시보드 UI (단일 파일, 외부 의존성 없음)
├── Dockerfile          # nginx:alpine 기반
├── nginx.conf          # /state/dashboard.json 프록시 설정
├── docker-compose.yml  # 원클릭 실행
└── README.md           # 이 문서
```

## 관련 파일

| 파일 | 역할 |
|------|------|
| `bin/dashboard-collect.sh` | 데이터 수집 스크립트 |
| `bin/chamberlain.sh` | 수집기를 30초마다 호출 |
| `state/dashboard.json` | 수집 결과 (런타임 생성) |
