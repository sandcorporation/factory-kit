# 라벨

공장이 쓰는 라벨의 정본은 [`factory/labels.json`](../factory/labels.json)이다. 스크립트는 라벨 이름을 직접 쓰지 않고 `factory/lib/labels.sh`의 변수(`L_READY` 등)로만 읽는다. 이 파일은 `labels-sync.sh --gen`이 `labels.json`에서 만들고(`factory/labels-sync.sh:29-38`), 둘이 어긋나면 `factory/tests/labels.sh`가 실패한다.

## 그룹

`labels.json:3-24`. 배타 그룹은 한 이슈에 그 그룹 라벨이 하나만 붙는다(`L_EXCLUSIVE_GROUPS`, `factory/labels-sync.sh:36`).

| 그룹 | 배타 | 뜻 |
|---|---|---|
| `state` | 예 | 티켓·스펙이 공장의 어느 단계에 있는가 |
| `wait` | 아니오 | 공장이 사람을 기다리는 까닭. 여럿이 함께 붙을 수 있다 |
| `kind` | 예 | 이슈의 종류 |
| `model` | 예 | Implementer가 쓸 모델. 없으면 기본 모델 |
| `alert` | 아니오 | 공장이 남기는 알림 이슈 |

## 라벨과 옛 이름

`labels.json:25-144`. 「옛 이름」은 앞선 판에서 쓰던 이름이고, `labels-sync.sh --apply`가 그 라벨의 이름을 제자리에서 바꾼다(이슈에 붙은 라벨은 그대로 남는다).

| 라벨 | 그룹 | 옛 이름 | 뜻 |
|---|---|---|---|
| `state:ready` | state | `ready-for-agent` | 공장이 집어 갈 차례를 기다리는 티켓 |
| `state:running` | state | `in-progress` | Implementer·Verify가 다루는 중인 티켓 |
| `state:human` | state | `ready-for-human` | 공장이 사람에게 넘긴 이슈(까닭은 표지 댓글) |
| `state:deferred` | state | `deferred` | 사람이 미룬 이슈. 공장은 건너뛴다 |
| `wait:decision` | wait | `needs-decision` | 주인의 결정을 기다리는 질문 |
| `wait:budget` | wait | `factory-paused` | 예산에 닿아 멈춘 스펙 |
| `wait:check` | wait | `human-check` | 사람이 확인해야 할 항목이 남은 이슈 |
| `kind:spec` | kind | `spec` | 티켓으로 나눌 스펙 |
| `kind:ledger` | kind | `factory-ledger` | 공장 비용 장부(열린 것 하나) |
| `kind:local` | kind | `local` | 공장 밖에서 로컬 작업자가 할 티켓 |
| `model:strong` | model | `model:opus` | 어려운 티켓: 강한 모델(`models.strong`)로 구현 |
| `bench-alert` | alert | | 벤치마크 회귀 알림이 달리는 이슈 |

## 없앤 라벨

`labels.json:145-` 의 `removed`. 공장은 더 읽지 않는다.

| 라벨 | 까닭 |
|---|---|
| `spec-pr` | 붙이기만 하고 읽는 곳이 없었다 |
| `model:sonnet` | 모델 라벨이 없으면 기본 모델이다 |

`labels-sync.sh`는 이 라벨을 **지우지 않고 보고만 한다**(`factory/labels-sync.sh:10-11`, `:94`). 라벨을 지우면 모든 이슈에서 떨어지고 되돌릴 수 없으므로, 보고를 읽고 사람이 `gh label delete`로 지운다.

## `labels-sync.sh` 쓰기

저장소 라벨을 `labels.json`에 맞춘다. 저장소 루트에서(또는 `REPO=owner/name`을 주고) 부른다.

```sh
bash factory/labels-sync.sh            # 드라이런: 할 일만 출력
bash factory/labels-sync.sh --apply    # 실제로 바꾸고, 앞뒤 라벨 목록의 차이를 출력
bash factory/labels-sync.sh --gen      # factory/lib/labels.sh 다시 만들기(네트워크 없음)
```

- 기본은 드라이런이다(`factory/labels-sync.sh:5`, `:107`).
- 할 일은 줄마다 하나다(`:71-83`): 옛 이름이 있으면 `rename`, 없으면 `create`, 색·설명이 다르면 `fix`, 없앤 라벨이 남아 있으면 `remove`(보고만).
- `labels.json`에 없는 라벨(저장소가 따로 쓰는 라벨)은 건드리지 않는다. 계획은 정의된 라벨과 `removed`만으로 만든다.
- 저장소 파일(`labels.scan`, 기본 `.github/`)에 옛 이름이 남아 있으면 그 줄을 알린다. 고치지는 않는다(`:54-68`).
- 환경 변수: `REPO`(기본: 현재 폴더의 저장소), `FACTORY_LABELS`(정의 파일), `LABELS_SNAPSHOT_DIR`(앞뒤 목록을 둘 폴더), `FACTORY_REPO_DIR`·`FACTORY_LABELS_SCAN`(옛 이름 훑기) (`:12-14`, `:55-58`).
