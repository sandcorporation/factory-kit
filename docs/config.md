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
| `base` | `main` | 티켓 PR의 기준 브랜치 | `factory-implementer.yml:647`(`gh pr create`). 아래 「어긋남」 참고 |
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

## 어긋남(코드는 아직 그대로)

- `base`를 바꿔도 여러 곳이 `origin/main`을 그대로 쓴다: `factory-implementer.yml:424-515`·`:535`, `factory-verify.yml:169`·`:185`·`:188`, `factory/workflow-guard.sh:74-85`, `factory/acceptance-probe.sh:56`. 지금은 `base: main`으로만 쓴다.
- `cache`는 `rust`만 알아듣는다. 다른 값은 캐시 없이 돈다.
- `factory/decompose.sh:207-208`의 git 이름 대체값(`github-actions[bot]`)이 `git.name` 기본값(`factory[bot]`)과 다르다.
