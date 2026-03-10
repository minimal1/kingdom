# gen-doctor

실패 태스크 진단 장군. 이벤트/스케줄 없이, 사람의 DM 요청(petition)으로만 동작한다.

## 사용법

Slack DM으로 Kingdom에게 요청:

```
최근 실패한 작업 알려줘
task-20260309-001 왜 실패했어?
task-20260309-001 자세히 분석해줘
```

## 동작

1. 사용자 메시지를 분석하여 `bin/doctor.sh`에 전달할 인자를 결정
2. `bin/doctor.sh --recent` 또는 `bin/doctor.sh <task_id> [--deep]` 실행
3. 진단 결과를 요약하여 보고

## 설치

```bash
generals/gen-doctor/install.sh
```

## 패키지 구조

```
generals/gen-doctor/
├── manifest.yaml   # subscribes: [], schedules: []
├── prompt.md       # 진단 프롬프트 템플릿
├── install.sh      # 설치 스크립트
└── README.md       # 이 파일
```
