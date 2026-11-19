# 설정: `.github/factory.yml`

공장을 쓰는 저장소는 자기 저장소에 `.github/factory.yml`을 둔다. 파일이 없으면 모든 키가 기본값이다(`factory/config.sh:18`). 각 재사용 workflow의 `config` 잡과 작업 잡이 `bash "$FACTORY_KIT/factory/config.sh"`로 이 파일을 읽는다(예: `.github/workflows/factory-decompose.yml:54-64`).

예시는 [`examples/factory.yml`](../examples/factory.yml)에 있다.

## 문법

`config.sh`는 YAML 전체가 아니라 다음 부분집합만 읽는다(`factory/config.sh` 앞머리 주석과 파서).

- 들여쓰기는 공백 2칸이고 단계는 `상위.하위` 키가 된다(예: `runners:` 아래 `  default:` → `runners.default`). 탭은 오류다.
- 값은 따옴표로 감쌀 수 있고, 줄 끝 ` #` 뒤는 주석이다.
- `|` 블록 값(여러 줄)을 쓸 수 있다. `setup`·`checks.*`처럼 명령을 담는 키에 쓴다.
- 기본값이 `@다른.키`인 키는 그 키의 값을 따른다(`factory/config.sh:20`, `:102`). 이 꼴은 기본값에서만 풀린다. 설정 파일에 `@models.default`라고 쓰면 그 글자가 그대로 값이 된다.
- 모르는 키가 있으면 종료 코드 2로 멈춘다(`factory/config.sh:94`). 오타가 조용히 기본값이 되지 않게 하려는 것이다.

## 값이 가는 곳

- 키마다 `GITHUB_OUTPUT`에 `.`을 `_`로 바꾼 이름으로 쓴다(예: `runners.default` → `runners_default`) (`factory/config.sh:116-120`).
- 같은 값을 `GITHUB_ENV`에 `FACTORY_<대문자 키>`로 쓴다. `.`과 `-`는 `_`가 된다(예: `checks.full` → `FACTORY_CHECKS_FULL`) (`factory/config.sh:116-120`).
- 그 밖에 `FACTORY_REPO`(저장소)와 `FACTORY_CHECK`(= `checks.full`)를 쓴다(`factory/config.sh:121-122`).
- `env.<이름>` 키는 그 이름 그대로 `GITHUB_ENV`에 들어간다(`factory/config.sh:89-92`). 저장소마다 필요한 환경 변수를 여기에 둔다.

## 키

| 키 | 기본값 (`factory/config.sh`) | 뜻 | 쓰는 곳 |
|---|---|---|---|
| `repository` | 빈 값 → `$GITHUB_REPOSITORY` (`:21`, `:104`) | 공장이 다루는 저장소 `owner/name`. 환경 변수 `FACTORY_REPO`가 된다 | `factory/bench-gate.sh:22`, `factory/bridge.sh:124` 등 `FACTORY_REPO`를 읽는 스크립트 |
| `base` | `main` | 티켓 PR의 기준 브랜치. 받아 오기·합치기·rebase·검사 기준(`origin/<base>`)도 이것이다. 설정 없이 도는 스크립트는 `config.sh --default base`를 쓴다 | `factory-implementer.yml`·`factory-verify.yml`의 `$FACTORY_BASE`, `factory/workflow-guard.sh`, `factory/acceptance-probe.sh`, `factory/decompose.sh` |
| `runners.default` | `ubuntu-latest` | 가벼운 잡(설정·분해·티켓 고르기)의 러너 | `factory-decompose.yml:69`, `factory-implementer.yml:114`·`:140`·`:180`, `factory-resume.yml:72` |
| `runners.implement` | `@runners.default` | 구현·Odin 잡의 러너 | `factory-implementer.yml:203`, `factory-odin.yml:98` |
| `runners.verify` | `@runners.default` | Verify 잡의 러너 | `factory-verify.yml:88` |
| `setup` | 빈 값 | 작업 잡에서 코드를 돌리기 전에 실행할 셸 명령(도구 설치 등). 비면 `true` | `factory-decompose.yml:128`, `factory-implementer.yml:353`, `factory-odin.yml:199`, `factory-verify.yml:204` |
| `cache` | 빈 값 | 빌드 캐시 종류. 지금은 `rust`만 알아듣고 `Swatinem/rust-cache@v2`를 건다 | `factory-implementer.yml:355`, `factory-odin.yml:201`, `factory-verify.yml:206` |
| `checks.full` | 빈 값 | 머지 전 자동 검사 전체 명령. `FACTORY_CHECK`로도 나간다 | `factory-implementer.yml:550`·`:590`, `factory-odin.yml:321`·`:375`, `factory-verify.yml:214` |
| `checks.kill` | 빈 값 | 검사 전에 남은 프로세스를 정리하는 명령 | `factory-implementer.yml:547`·`:587`, `factory-odin.yml:317`·`:372` |
| `checks.quick` | 빈 값 | Odin이 스펙 PR에서 돌리는 빠른 검사 | `factory-odin.yml:323-324`·`:377` |
| `git.name` | `factory[bot]` | 공장 커밋의 작성자 이름 | `factory-implementer.yml:336-337`, `factory-odin.yml:167-168`, `factory-verify.yml:150-151` |
| `git.email` | `41898282+github-actions[bot]@users.noreply.github.com` | 공장 커밋의 작성자 메일 | 위와 같음 |
| `models.default` | `claude-sonnet-5-5` | 구현 기본 모델 | `factory-implementer.yml:322-326` |
| `models.strong` | `claude-opus-5-5` | 강한 모델. `model:strong` 라벨이 있거나 앞서 실패한 티켓에 쓴다 | `factory-implementer.yml:322-326` |
| `models.decompose` | `@models.strong` | 스펙을 티켓으로 나누는 모델 | `factory-decompose.yml:145` |
| `models.odin` | `@models.strong` | 스펙 PR 검토·충돌 풀기 모델 | `factory-odin.yml:242`·`:288`·`:355` |
| `models.verify` | `@models.default` | 인수 검토 모델 | `factory-verify.yml:253` |
| `turns.implement` | `200` | 구현 에이전트 최대 턴 | `factory-implementer.yml:387` |
| `turns.conflicts` | `60` | 충돌 풀기 최대 턴 | `factory-implementer.yml:483`, `factory-odin.yml:243`·`:356` |
| `turns.fix` | `80` | 검사 실패 고치기 최대 턴 | `factory-implementer.yml:571` |
| `turns.decompose` | `120` | 분해 최대 턴 | `factory-decompose.yml:146` |
| `turns.odin` | `60` | Odin 검토 최대 턴 | `factory-odin.yml:289` |
| `turns.verify` | `40` | 인수 검토 최대 턴 | `factory-verify.yml:254` |
| `labels.scan` | `.github/` | `labels-sync.sh`가 옛 라벨 이름이 남았는지 훑을 경로 | `factory/labels-sync.sh:55-58` |
| `acceptance.glob` | `crates/*/tests/spec_*.rs` | 인수 시험 파일의 git 경로 패턴. 공백으로 나눠 여러 개를 쓴다(`crates/*/tests/spec_*.rs web/tests/*.spec.ts`). 분해가 커밋하는 파일, Verify가 「인수 시험을 고쳤다」를 보는 범위 | `factory/spec-tests.sh:26`, `factory/decompose.sh`, `factory/verify.sh`, `factory/acceptance-probe.sh` (`FACTORY_ACCEPTANCE_GLOB`) |
| `acceptance.marker` | `#\[ignore = "#{n}"\]` | 티켓 N이 아직 통과시키지 않은 인수 시험의 표지(확장 정규식, `{n}`이 티켓 번호). 구현이 지우고, 남아 있으면 분해·Verify가 「아직」으로 본다 | `factory/spec-tests.sh:24` (`FACTORY_ACCEPTANCE_MARKER`) |
| `acceptance.markers` | 빈 값 | 파일마다 다른 표지. 여러 줄 블록(YAML 블록 문자열)에 한 줄에 `<glob> <정규식>`. 있으면 그 glob에 맞는 파일만 그 정규식으로 찾는다(여러 언어 저장소) | `factory/spec-tests.sh:25` (`FACTORY_ACCEPTANCE_MARKERS`) |
| `merge.timeout` | `20` | `merge-pr.sh`가 필수 검사를 기다리는 전체 시간(분). 넘으면 종료 코드 3 | `factory/merge-pr.sh:31` (`FACTORY_MERGE_TIMEOUT`) |
| `merge.interval` | `15` | `merge-pr.sh`의 검사 확인 간격(초) | `factory/merge-pr.sh:32` (`FACTORY_MERGE_INTERVAL`) |
| `app.enabled` | `true` | GitHub App 토큰으로 push·PR·병합하는가. 켜짐인데 토큰(`FACTORY_APP_ID`·`FACTORY_APP_PRIVATE_KEY` 비밀)이 없으면 오류. 꺼짐이면 App 단계를 건너뛰고 `GITHUB_TOKEN`으로 하며 경고만 낸다(그 push는 CI를 띄우지 않는다) | `factory/app-git.sh:12`, workflow 4개의 `App token` 단계 (`FACTORY_APP_ENABLED`) |
| `human_check.enabled` | `false` | 켜면 spec의 티켓이 모두 끝났을 때 spec에 `wait:check`를 붙이고 사람이 그 라벨을 뗄 때까지 닫지 않는다 | `factory/human-check.sh:19`, `factory/dispatch-next.sh:306`·`:317` (`FACTORY_HUMAN_CHECK_ENABLED`) |
| `env.<이름>` | 없음 | 그 이름의 환경 변수 | 작업 잡 전체 (`factory/config.sh:89-92`) |

표의 workflow 경로는 모두 `.github/workflows/` 아래다.

## 저장소 변수(`vars`)

설정 파일 밖에서, 저장소의 Actions 변수로 주는 값이 있다. workflow가 그대로 환경 변수로 넘긴다(`factory-implementer.yml:65-73`, `factory-odin.yml:67-70`, `factory-verify.yml:56-60`, `factory-resume.yml:79-82`, `factory-decompose.yml:76-77`).

| 변수 | 뜻 |
|---|---|
| `FACTORY_TRACKS` | 구현 트랙 수(비면 2). `1`이면 구현과 Verify가 한 동시성 그룹을 쓴다(`factory-implementer.yml:214`, `factory-verify.yml:95`) |
| `FACTORY_SPEC_QUEUE` | 스펙 처리 차례 |
| `FACTORY_SPEC_BUDGET_USD` | 스펙 하나의 비용 상한 |
| `FACTORY_DAILY_BUDGET_USD` | 하루 비용 상한 |

## workflow 파일 이름

스크립트는 다른 workflow를 파일 이름으로 띄운다. 부르는 쪽 workflow 파일을 다른 이름으로 두었으면 `env.*`로 다음 변수를 준다. 기본값은 `factory-<이름>.yml`이다.

| 변수 | 기본 | 쓰는 곳 |
|---|---|---|
| `FACTORY_IMPLEMENTER_WORKFLOW` | `factory-implementer.yml` | `factory/dispatch-next.sh:121`·`:146`·`:154`·`:157` |
| `FACTORY_DECOMPOSE_WORKFLOW` | `factory-decompose.yml` | `factory/dispatch-next.sh:290`·`:298`·`:341`, `factory/resume.sh:96` |
| `FACTORY_ODIN_WORKFLOW` | `factory-odin.yml` | `factory/decompose.sh:152`, `factory/odin.sh:263` |
| `FACTORY_VERIFY_WORKFLOW` | `factory-verify.yml` | `factory/verify.sh:285`·`:316`, `factory/resume.sh:108` |

## 서비스 띄우기(`setup`에서 docker run)

시험에 DB·캐시 같은 서비스가 필요하면 `setup` 셸에서 `docker run`으로 띄운다. 재사용 workflow의 `services:`는 caller가 바꿀 수 없고 식을 받지 않으므로, 저장소마다 다른 서비스는 셸이 가장 좁은 자리다. 포트를 열고 헬스 체크가 통과할 때까지 기다린 뒤 끝낸다.

```yaml
setup: |
  docker run -d --name db -p 5432:5432 -e POSTGRES_PASSWORD=test postgres:16
  for i in $(seq 1 30); do docker exec db pg_isready -U postgres && break; sleep 1; done
  docker exec db pg_isready -U postgres
env.DATABASE_URL: postgres://postgres:test@localhost:5432/postgres
```

## toolchain은 `setup` 셸로

`actions/setup-python` 같은 단계는 workflow의 `uses:`에 들어가야 하는데 `uses:`는 식(`${{ }}`)을 받지 않아 설정 파일로 고를 수 없다. 언어 도구는 `setup` 셸로 설치한다.

- python: `setup: pipx install uv && uv python install 3.12 && uv sync`
- node: `setup: corepack enable && pnpm install --frozen-lockfile`
- go: `setup: curl -sSfL https://go.dev/dl/go1.23.4.linux-amd64.tar.gz | sudo tar -C /usr/local -xz && echo /usr/local/go/bin >> "$GITHUB_PATH"`

## 사람 확인(`human_check.enabled`)

`dispatch-next.sh`가 spec을 닫는 두 곳(티켓이 모두 병합됨 `:306`, 남은 것이 미룬 티켓뿐 `:317`) 바로 앞에서 `factory/human-check.sh <spec>`을 부른다. 꺼져 있으면 그대로 닫는다. 켜져 있으면 처음에 `wait:check` 라벨과 표지 댓글 `<!-- factory-human-check SPEC -->`을 달고(bridge가 사람 확인 메일로 보낸다) 닫지 않는다. 사람이 확인하고 라벨을 떼면 다음 dispatch 때 spec이 닫힌다. 다른 자리에서 사람 확인을 끼우려면 그 자리에서 같은 스크립트를 불러 종료 코드 0일 때만 다음으로 간다(1: 기다림, 2: GitHub 호출 실패).

## 병합(`merge-pr.sh`)

Odin과 Verify는 `factory/merge-pr.sh <PR>`로 병합한다. 기준 브랜치의 필수 검사를 rulesets(`rules/branches/<base>`)와 branch protection에서 읽고(둘 다 못 읽으면 PR의 모든 검사를 기다림), 모두 초록이면 App 토큰으로 squash 병합한다. `mergeable`이 아직 null이면 다시 본다. 종료 코드: 0 병합됨, 1 사용법·읽기 실패, 2 필수 검사 실패, 3 시간 초과(`merge.timeout`), 4 닫힘·충돌.

## 알려진 한계

README의 「알려진 한계」를 본다. 스크립트가 설정 env 없이 돌 때는 `bash factory/config.sh --default <키>`로 이 표의 기본값을 한 곳에서 가져온다(`git.name`·`git.email`·`base`·`acceptance.glob`).
