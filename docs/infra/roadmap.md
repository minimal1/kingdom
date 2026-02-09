# 구현 로드맵

> 단계별로 검증하며 진행한다. 한번에 다 만들지 않는다.

## Phase 1: 기반 환경 (Week 1)

**목표**: EC2에서 Claude Code가 정상 동작하고, 기본 인프라가 갖춰진다.

- [ ] EC2 인스턴스 프로비저닝 (M5.xlarge)
- [ ] 필수 소프트웨어 설치
- [ ] Claude Code headless 인증 확인
- [ ] `claude -p "hello world"` 정상 동작 테스트
- [ ] tmux 세션 매니저 스크립트 (`start.sh`, `stop.sh`, `status.sh`)
- [ ] 파일 시스템 디렉토리 구조 생성 (초기화 스크립트)
- [ ] 내관 기본 구현 (`chamberlain.sh` — 리소스 모니터링 + heartbeat 감시 + 세션 정리)
- [ ] `state/resources.json` 갱신 확인
- [ ] heartbeat 감시 동작 확인 (Phase 2 전제조건: 파수꾼/사절 감시)

**검증**: `bin/start.sh`로 시작, `bin/status.sh`로 상태 확인, `bin/stop.sh`로 종료.

---

## Phase 2: 파수꾼 + 사절 (Week 2)

**목표**: 외부 이벤트를 감지하고, 사람에게 알림을 보낼 수 있다.

- [ ] 파수꾼: GitHub polling (`gh` CLI)
- [ ] 파수꾼: Jira polling (curl + REST API)
- [ ] 파수꾼: 중복 방지 메커니즘
- [ ] 이벤트 큐 동작 확인 (event.json 생성 → pending 디렉토리)
- [ ] 사절: Slack 메시지 발송 (Slack Web API)
- [ ] 사절: 기본 알림 형식 구현
- [ ] 연동 테스트: 새 PR 생성 → 이벤트 감지 → Slack 알림

**검증**: GitHub에 테스트 PR 생성 → 2분 내 Slack 알림 수신.

---

## Phase 3: 왕 + 장군 (Week 3-4)

**목표**: 이벤트가 자동으로 작업으로 변환되고, 병사가 실제 작업을 수행한다.

- [ ] 왕: 이벤트 소비 loop
- [ ] 왕: 라우팅 규칙 (이벤트 → 장군 매핑)
- [ ] 왕: 리소스 기반 행동 규칙
- [ ] 왕: 병사 수 제한 (max_soldiers)
- [ ] 장군 공통: 루프 프레임워크 (`lib/general/common.sh`)
- [ ] 장군 공통: 프롬프트 빌더 (`lib/general/prompt-builder.sh`)
- [ ] 장군 공통: 병사 생성 (장군 `spawn_soldier()` → 검증 후 `bin/spawn-soldier.sh` 호출)
- [ ] PR Review 장군: friday 플러그인 연동
- [ ] Jira Ticket 장군: sunday 플러그인 연동
- [ ] 품질 게이트 기본 구현
- [ ] 결과 보고 흐름 (병사 → 장군 → 왕)

**검증**: 새 PR → 이벤트 감지 → 왕 배정 → 장군 처리 → 병사 리뷰 → Slack 완료 알림.

---

## Phase 4: 안정화 + 확장 (Week 5+)

**목표**: 시스템이 안정적으로 장시간 운영되고, 기능이 확장된다.

- [ ] Test Code 장군 구현
- [ ] 메모리 관리 고도화 (크기 제한, 정리 규칙)
- [ ] 내관: 자동 복구 (세션 재시작)
- [ ] 내관: 로그 로테이션
- [ ] 리포트: 내관이 데이터 수집 + 메시지 생성, 사절이 Slack 발송
- [ ] 사절: 사람 응답 수신 (승인/거부)
- [ ] 에러 복구 메커니즘 (재시도, 에스컬레이션)
- [ ] 실패 분석 자동 수집
- [ ] 대시보드 (선택: 웹 또는 터미널)

---

## 각 Phase 완료 기준

| Phase | 완료 기준 |
|-------|----------|
| 1 | EC2에서 Claude Code `-p`가 정상 실행됨 |
| 2 | 외부 이벤트 → Slack 알림이 자동으로 동작함 |
| 3 | PR 생성 → 자동 리뷰 → 코멘트 제출이 End-to-End로 동작함 |
| 4 | 24시간 이상 무중단 운영, 일일 리포트 자동 발송 |
