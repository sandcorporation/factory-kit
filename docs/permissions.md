# 권한

공장은 토큰 두 개를 나눠 쓴다.

- **GitHub App 토큰**: push, PR 만들기, PR 병합만. 이 토큰으로 한 push와 PR은 사용자 저장소의 CI(`pull_request`·`push` workflow)를 띄운다. `GITHUB_TOKEN`으로 한 push는 다른 workflow를 띄우지 않기 때문이다(`factory/app-git.sh:1-5`).
- **`GITHUB_TOKEN`**: 그 밖의 모든 것. 이슈 읽기, 라벨 붙이고 떼기, 댓글, 이슈 닫기, 다른 workflow 띄우기(`gh workflow run`, `dispatches`), run 목록 읽기.

## App이 받아야 할 권한

App 설치 권한은 이것뿐이다.

| 권한 | 수준 | 까닭 |
|---|---|---|
| Contents | 읽기·쓰기 | 브랜치 push(`factory/app-git.sh:11-14`), PR 병합(`factory/odin.sh:198`, `factory/verify.sh:234`) |
| Pull requests | 읽기·쓰기 | PR 만들기(`factory/decompose.sh:220`, `.github/workflows/factory-implementer.yml:647`), PR 병합 |
| Metadata | 읽기 | GitHub App이면 늘 붙는 기본 권한 |

토큰을 만드는 단계는 workflow마다 `actions/create-github-app-token`(커밋 고정 `f418cff399f7aef4c2f0ad47e25ca7a6abbdd6fc`, v3.4.0)이고 `permission-contents: write`와 `permission-pull-requests: write`만 청한다.

| workflow | App 토큰 단계 |
|---|---|
| `factory-decompose.yml` | `:91-101` |
| `factory-implementer.yml` | `:244-254` |
| `factory-odin.yml` | `:124-134` |
| `factory-verify.yml` | `:121-131` |
| `factory-resume.yml` | 없음(push·PR을 하지 않음) |

만든 토큰은 `FACTORY_APP_TOKEN` 환경 변수로 넘어가고, push 직전에 `factory/app-git.sh`가 git 인증 헤더를 그 토큰으로 바꾼다. `FACTORY_APP_TOKEN`이 없으면 경고만 하고 `GITHUB_TOKEN`으로 push한다(`factory/app-git.sh:7-10`). 그때는 CI가 그 push에서 돌지 않는다.

App에 **Issues·Actions·Workflows 권한을 주지 않는다**. 라벨·댓글·닫기·dispatch는 `GITHUB_TOKEN`이 한다.

## workflow 파일을 바꾸는 티켓은 사람에게

App에 Workflows 권한이 없으므로 `.github/workflows/` 아래 파일을 만들거나 고치는 push는 GitHub이 거절한다. 공장은 그런 티켓을 실패로 세어 다시 돌리지 않고 곧바로 사람에게 넘긴다(`factory/workflow-guard.sh:1-28`).

- 고르는 단계에서: 「Keep workflow tickets out」(`.github/workflows/factory-implementer.yml:166-171`, `factory/local-ticket.sh`)
- 구현 뒤 검사 전: 「Workflow file guard」가 `workflow-guard.sh check`로 브랜치 커밋이 `.github/workflows/`를 건드렸는지 본다(`.github/workflows/factory-implementer.yml:532-535`)
- push가 거절되면: `workflow-guard.sh push-retry`가 main을 따라잡아 한 번 더 push하고, 그래도 안 되면 넘긴다(`.github/workflows/factory-implementer.yml:622`, `factory/workflow-guard.sh:18-25`)

## workflow 권한(`GITHUB_TOKEN`의 상한)

| workflow | `permissions` |
|---|---|
| `factory-decompose.yml:35-40` | contents·pull-requests·issues·actions·id-token 쓰기 |
| `factory-implementer.yml:58-63` | 위와 같음 |
| `factory-odin.yml:57-62` | 위와 같음 |
| `factory-verify.yml:47-52` | 위와 같음 |
| `factory-resume.yml:35-40` | contents·pull-requests 읽기, issues·actions 쓰기 |

재사용 workflow의 권한은 부르는 쪽 workflow가 준 권한을 넘지 못한다. 부르는 쪽 잡에 같은 `permissions`를 적는다([`examples/caller.yml`](../examples/caller.yml)).

## 잡·단계별 토큰

경로는 모두 `.github/workflows/` 아래다. 「GH」는 잡 환경의 `GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`이다.

### factory-decompose.yml

| 잡·단계 | 토큰 | 하는 일 | 근거 |
|---|---|---|---|
| `config` | 없음 | 설정 읽기 | `:43` |
| `decompose` 잡 | GH | 스펙 이슈 읽기, 라벨·댓글 | `:66`, `:73` |
| GitHub App token / Hand the token on | App 만들기 | contents·pull-requests 쓰기 토큰 | `:91-101` |
| Budget guard | GH | 비용 상한 확인, 넘으면 라벨 | `:105` |
| Decompose | GH | 에이전트가 티켓 이슈를 만듦 | `:130` |
| Open spec PR | App(push·PR), GH(그 밖) | 인수 시험 브랜치 push와 스펙 PR, Odin 띄우기는 GH | `:156`, `factory/decompose.sh:152`·`:210`·`:220` |

### factory-implementer.yml

| 잡·단계 | 토큰 | 하는 일 | 근거 |
|---|---|---|---|
| `config` | 없음 | 설정 읽기 | `:86` |
| `frontier` | GH | 이슈가 닫히면 빈 트랙에 다음 티켓 띄우기 | `:111`, `:116`, `:131` |
| `approved` | GH | `state:ready`가 붙으면 상위 스펙 확인, workflow 티켓 걸러내기, 띄우기 | `:137`, `:142`, `:159`, `:166`, `:172` |
| `resume` | GH | 예약 실행에서 다음 티켓 띄우기 | `:177`, `:182`, `:197` |
| `implement` 잡 | GH | 티켓 읽기, 라벨·댓글 | `:200`, `:224` |
| GitHub App token / Hand the token on | App 만들기 | | `:244-254` |
| Budget guard, Guard and claim | GH | 비용 확인, `state:running` 붙이기 | `:258`, `:262` |
| Implement, Resolve conflicts, Fix | (에이전트) | 코드 고치기·커밋. push하지 않음 | `:372`, `:465`, `:552` |
| Workflow file guard | GH | workflow 파일을 건드리면 사람에게 | `:532-535` |
| Push and open PR | App(push·`gh pr create`), GH(PR 본문 고치기·이슈 읽기) | | `:595`, `:612`, `:647` |
| Hand over to Verify, Record failure, Dispatch next | GH | 라벨·댓글, Verify·다음 티켓 띄우기 | `:657`, `:674`, `:697` |

### factory-odin.yml

| 잡·단계 | 토큰 | 하는 일 | 근거 |
|---|---|---|---|
| `config` | 없음 | 설정 읽기 | `:73` |
| `odin` 잡 | GH | 스펙 PR 찾기, 라벨·댓글 | `:96`, `:105`, `:143` |
| GitHub App token / Hand the token on | App 만들기 | | `:124-134` |
| Review, Resolve conflicts, Fix | (에이전트) | 검토·충돌 풀기·고치기 | `:269`, `:219`, `:332` |
| Push fixes | App | 고친 커밋 push | `:386`, `:398` |
| Merge | App(병합), GH(그 밖) | 스펙 PR 병합 | `:401`, `factory/odin.sh:198` |

### factory-verify.yml

| 잡·단계 | 토큰 | 하는 일 | 근거 |
|---|---|---|---|
| `config` | 없음 | 설정 읽기 | `:63` |
| `verify` 잡 | GH | 티켓·PR 읽기, 라벨·댓글 | `:86`, `:103` |
| GitHub App token / Hand the token on | App 만들기 | | `:121-131` |
| Machine checks, Merge main, Automated checks | GH | 검사 | `:165`, `:178`, `:209` |
| Push merged | App | main을 merge한 커밋 push | `:217`, `:223` |
| Acceptance review | (에이전트) | 인수 검토 | `:239` |
| Merge or send back | App(병합), GH(되돌려 보내기·라벨) | | `:261`, `factory/verify.sh:234` |
| Dispatch next, Start Verify waiting | GH | 다음 티켓·기다리던 Verify 띄우기 | `:324`, `:330`, `factory/verify.sh:316` |

### factory-resume.yml

| 잡·단계 | 토큰 | 하는 일 | 근거 |
|---|---|---|---|
| `config` | 없음 | 설정 읽기 | `:42` |
| `resume` 잡 / Resume | GH | 멈춘 스펙을 다시 띄우기(분해·Verify) | `:65`, `:76`, `:98`, `factory/resume.sh:96`·`:108` |

## 정적 검사: `factory/tests/permissions.sh`

`bash factory/test.sh`가 함께 돌린다. workflow 파일을 고쳐 위 규칙이 깨지면 실패한다.

- App 토큰 단계가 `permission-contents: write`·`permission-pull-requests: write` 밖의 권한을 청하면 실패(`factory/tests/permissions.sh:10-16`)
- `create-github-app-token`이 40자 커밋으로 고정되지 않았으면 실패(`:17`)
- workflow에서 `steps.app.outputs.token`이 `gh issue`·`gh label`·`gh workflow run`·`dispatches`·이슈·라벨 쓰기 API에 쓰이면 실패(`:18-19`)
- `factory/*.sh`에서 `FACTORY_APP_TOKEN`이 같은 호출에 쓰이면 실패(`:21-23`)
- 검사기가 일부러 심은 나쁜 줄을 잡는지 스스로 확인한다(`:24-29`)

출력은 `permissions: <workflow 수> workflows, <실패 수> failed`다.
