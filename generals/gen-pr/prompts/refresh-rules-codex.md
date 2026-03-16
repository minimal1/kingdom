# Frontend 리뷰 규칙 학습

## 대상
- 레포: {{REPO}}
- 브랜치: develop (guide-branch)
- 경로 우선순위:
  1. `apps/front/.codex/skills/frontend-doc/`
  2. `apps/front/.claude/skills/frontend-doc/`

## 작업
1. Codex skill 경로가 있으면 그것을 우선 읽는다
2. 없으면 Claude skill 경로를 읽는다
3. 핵심 규칙만 추출해서 3KB 이내 요약 작성

## 출력 형식
파일 경로: ../../memory/generals/gen-pr/review-rules.md

```markdown
# Frontend Review Rules (auto-generated)
## 갱신일: YYYY-MM-DD
## 소스: selected frontend-doc skill path

### 컴포넌트 규칙
- ...
### 상태 관리 규칙
- ...
### 타입/패턴 규칙
- ...
### 금지 패턴
- ...
```

규칙의 "왜"는 생략하고 "무엇"과 "어떻게"만 남긴다.
