# factory-kit

GitHub Actions 위에서 도는 소프트웨어 공장의 공유 부품이다. 스펙 이슈를 티켓으로 나누고(분해), 티켓을 구현해 PR을 열고(Implementer), PR을 인수 검토해 병합하고(Verify), 스펙 PR을 검토·병합한다(Odin). 공장을 쓰는 저장소는 이 저장소의 재사용 workflow를 부르는 짧은 caller workflow와 설정 파일 하나만 둔다.

## 배치

| 경로 | 내용 |
|---|---|
| `.github/workflows/factory-{decompose,implementer,odin,resume,verify}.yml` | 재사용 workflow(`on: workflow_call`, 예: `.github/workflows/factory-decompose.yml:8`) |
| `factory/*.sh`, `factory/*.md` | workflow가 부르는 스크립트와 에이전트 지시문 |
| `factory/config.sh` | 사용자 저장소의 `.github/factory.yml`을 읽는 파서 |
| `factory/labels.json`, `factory/labels-sync.sh` | 라벨 정의와 저장소 라벨 맞추기 |
| `factory/test.sh`, `factory/tests/` | 공장 스크립트 시험(가짜 `gh`) |
| `docs/` | [설정](docs/config.md), [권한](docs/permissions.md), [라벨](docs/labels.md) |
| `examples/` | [caller workflow](examples/caller.yml), [설정 파일](examples/factory.yml) |

재사용 workflow는 입력 `kit-repository`·`kit-ref`(`.github/workflows/factory-decompose.yml:10-17`)로 이 저장소의 그 판을 러너에 내려받아 `factory/` 스크립트를 쓴다(`:54-64`).

## 빠른 시작

1. **GitHub App을 만든다.** 권한은 Contents 읽기·쓰기, Pull requests 읽기·쓰기뿐이다(까닭은 [docs/permissions.md](docs/permissions.md)). 공장 저장소에 설치한다.
2. **secret 셋을 저장소에 둔다.** 다섯 재사용 workflow가 모두 필수로 받는다(`.github/workflows/factory-decompose.yml:23-29`).

   | secret | 값 | 쓰는 곳 |
   |---|---|---|
   | `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code 인증 토큰 | 에이전트 단계(`factory-decompose.yml:134`) |
   | `FACTORY_APP_ID` | 1의 App ID | App 토큰 만들기(`factory-decompose.yml:95`) |
   | `FACTORY_APP_PRIVATE_KEY` | 1의 App 개인 키 | App 토큰 만들기(`factory-decompose.yml:96`) |

3. **caller workflow 다섯 개를 둔다.** [`examples/caller.yml`](examples/caller.yml)의 문서마다 머리에 적힌 경로(`.github/workflows/factory-<이름>.yml`)로 저장한다. 파일 이름은 스크립트가 다른 workflow를 띄울 때 쓰므로 바꾸지 않는다(바꿨다면 [docs/config.md](docs/config.md)의 「workflow 파일 이름」).
4. **설정 파일을 둔다.** [`examples/factory.yml`](examples/factory.yml)을 `.github/factory.yml`로 복사해 고친다. 없으면 모든 키가 기본값이다.
5. **라벨을 맞춘다.** 아래 `labels-sync`.
6. 필요하면 저장소 Actions 변수(`FACTORY_TRACKS`, 비용 상한 등)를 둔다([docs/config.md](docs/config.md)의 「저장소 변수」).

그 뒤 스펙 이슈에 `kind:spec` 라벨을 붙이면 분해가 시작된다(`.github/workflows/factory-decompose.yml:68`).

## labels-sync

공장 저장소 루트에서 이 저장소의 스크립트로 부른다. 기본은 드라이런이다.

```sh
REPO=owner/name bash factory/labels-sync.sh          # 할 일만 출력
REPO=owner/name bash factory/labels-sync.sh --apply  # 저장소 라벨을 labels.json에 맞춤
```

옛 이름 라벨은 제자리에서 이름을 바꾸고, 없앤 라벨은 지우지 않고 보고만 한다. 자세한 것은 [docs/labels.md](docs/labels.md).

## 태그로 판 고정

caller의 `uses: …@<태그>`와 `kit-ref: <태그>`를 **같은 태그**로 둔다. `uses:`는 workflow 파일의 판을, `kit-ref`는 그 workflow가 내려받을 `factory/` 스크립트의 판을 정한다. 둘이 다르면 workflow와 스크립트가 서로 다른 판이 된다. 브랜치 이름을 쓰면 그 브랜치가 움직일 때마다 공장이 바뀌므로 태그나 커밋으로 고정한다(`kit-ref` 입력 설명, `.github/workflows/factory-decompose.yml:15`).

## 알려진 한계

- rust·Windows 전제가 남아 있다: `cache`는 `rust`만 알아듣고, Odin 탐침 로그 이름이 `probe-cargo.log`이며, 분해 잡에 「Prepare rustfmt」 단계가 있고, 프로세스 정리에 `taskkill`을 쓴다.
- 하루 경계(비용 장부·상한)는 KST 자정으로 고정돼 있다.
- caller workflow는 `run-name`을 kit에서 복사해 와야 한다(재사용 workflow의 `run-name`은 caller에 적용되지 않는다).
- 인수 시험의 표지 기본값은 rust `#[ignore = "#N"]`다. 다른 언어는 `acceptance.marker`·`acceptance.markers`로 바꾼다.
- 언어 도구와 서비스는 `setup` 셸로 설치·실행한다(`uses:`·`services:`는 식을 받지 않아 설정으로 고를 수 없다, docs/config.md).
- `app.enabled: false`면 공장의 push가 CI를 띄우지 않는다(`GITHUB_TOKEN`의 push는 workflow를 시작하지 않는다). 그래서 `merge-pr.sh`는 검사가 없는 PR에서 기다리다 시간 초과로 끝난다.
- `human_check.enabled`의 확인 항목은 spec 하나에 한 줄이다. 무엇을 볼지는 spec 본문에 적는다.
- 기본값의 `@키`(다른 설정 따르기)는 기본값 표에서만 해석한다. 설정 파일에 `@models.strong`처럼 쓰면 그 글자가 값이 된다.

## 시험

```sh
bash factory/test.sh
```

`factory/tests/*.sh`를 모두 돌리고 하나라도 실패하면 종료 코드 1이다(`factory/test.sh:1-3`). 가짜 `gh`를 PATH 앞에 두므로 네트워크가 필요 없고, `jq`가 없으면 건너뛴다(`:9-12`). CI(`.github/workflows/ci.yml`)는 모든 `.sh`의 `bash -n`, actionlint, 이 시험을 돌린다.
