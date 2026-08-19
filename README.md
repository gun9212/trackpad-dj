# Trackpad DJ

맥북 내장 트랙패드와 키보드만으로 간단한 2덱 믹싱이 가능한지 검증하는 macOS 실험 앱입니다. 프로 DJ 하드웨어를 복제하기보다 로드, 트랜스포트, 기본 스크래치, 템포, 필터, 볼륨, 크로스페이드와 프리큐가 한 흐름으로 동작하는 데 집중합니다.

## 요구 사항

- macOS 13 이상
- Swift 5.9 이상
- 멀티터치 간접 입력을 제공하는 맥북 내장 트랙패드
- Split Cue 청취 시 좌우 채널을 분리해 들을 수 있는 스테레오 헤드폰 또는 출력 장치

오디오 엔진은 AVFoundation을 사용합니다. 동시성 경계에는 `swift-atomics` 1.2.0을 고정해 사용하며, 별도 오디오 런타임 설치는 필요하지 않습니다.

## 빌드, 실행, 테스트

```bash
swift build
.build/debug/TrackpadDJ
swift test
Scripts/verify-strict-concurrency.sh
```

엄격 동시성 스크립트는 `-strict-concurrency=complete -warnings-as-errors`로 별도 빌드합니다.

## 현재 상태

안정화 MVP 소스와 자동화 테스트는 구현돼 있습니다.

- 제스처 시작 존 고정, 존별 첫 터치 제어, 우세 축 잠금과 정지 감지
- 렌더러 단독 재생 위치와 atomic 실시간 명령 경계
- 백그라운드 디코딩·파형 계산, 덱별 최신 로드 요청 우선 처리
- 덱별 ±8% Varispeed 템포와 Equal-power 크로스페이더
- 기본 스테레오 마스터와 선택형 Split Cue
- 오디오 엔진 스냅샷 기반 UI와 미작동 핫큐 표시 제거
- 런타임 WAV fixture를 사용하는 31개 자동 테스트

다만 빌드와 합성 신호 테스트는 실제 트랙패드 감각, 헤드폰 채널 청취, 레이턴시, 클릭 노이즈나 30분 연속 믹싱을 증명하지 않습니다. 이 항목은 맥북 실기기 검증이 남아 있습니다.

## 컨트롤

### 트랙패드

| 존 | 입력 | 기능 |
|---|---|---|
| 상단 왼쪽 / 오른쪽 | 한 손가락 수직 이동 | Deck A / B 볼륨 |
| Deck A / B | 터치 시작 또는 정지 | 해당 덱 프리즈, 스크래치 준비 |
| Deck A / B | 수직 이동 | 이동 속도와 방향에 비례한 스크래치 |
| Deck A / B | 수평 이동 | 해당 덱 로우패스 필터 |
| 하단 | 한 손가락 수평 이동 | 연속 크로스페이더 |

덱 존은 누적 이동 0.006 이상에서 축을 판정하고, 한 축이 다른 축보다 1.25배 우세할 때 해당 축으로 잠깁니다. 스크래치 목표 속도는 `위치 변화 / 시간 변화 × 3.3`으로 계산해 `-8...8`로 제한하며, 마지막 이동 후 50ms가 지나면 0으로 돌아갑니다. 터치 종료·취소 시 스크래치 상태를 해제합니다.

### 키보드

| 키 | 기능 |
|---|---|
| `Q` / `W` | Deck A / B 오디오 파일 선택 |
| `A` / `S` | Deck A / B 재생·정지 |
| `Z` / `X` | Deck A / B 큐, 2초 프리롤 시작점으로 복귀 |
| `E` / `D` | Deck A 볼륨 증가 / 감소 |
| `R` / `F` | Deck B 볼륨 증가 / 감소 |
| `T` / `G` | Deck A 필터 열기 / 닫기 |
| `Y` / `H` | Deck B 필터 열기 / 닫기 |
| `↑` / `↓` | Deck A 앞 / 뒤로 너지 |
| `I` / `K` | Deck B 앞 / 뒤로 너지 |
| `←` / `→` | 크로스페이더 `A → A+B → B` 전환 |
| `B` / `N` | Deck A / B 탭 BPM |
| `U` / `J` | Deck A 템포 증가 / 감소 |
| `O` / `L` | Deck B 템포 증가 / 감소 |
| `5` / `6` | Deck A / B 템포를 0%로 초기화 |
| `C` / `V` | Deck A / B 프리큐 선택 토글 |
| `M` | Stereo Master / Split Cue 전환 |

템포는 키를 누르는 동안 약 60fps로 0.05%씩 바뀝니다. Command, Control 또는 Option 조합은 앱이 가로채지 않고 macOS 단축키로 전달합니다. 핫큐 후보였던 `1`~`4`, `7`~`0`은 실제 덱 기능이 구현될 때까지 매핑하지 않습니다.

## Split Cue

기본 출력은 안전한 `Stereo Master`입니다. `M`을 눌러 명시적으로 Split Cue를 켜면 다음과 같이 출력합니다.

- 왼쪽: 포스트 페이더·포스트 크로스페이더 마스터의 모노 합산
- 오른쪽: `C`/`V`로 선택한 포스트 EQ·프리 페이더 덱의 모노 프리큐
- 두 덱을 동시에 모니터하면 각 프리큐를 0.5 게인으로 합산

Split Cue 중에는 화면 상단에 `L: MASTER / R: CUE` 경고가 계속 표시됩니다. 출력 장치 재구성에 실패하면 엔진을 중단하고 오류를 표시하며, 프리큐를 마스터로 자동 유출하지 않습니다.

## 오디오와 입력 구조

```text
원시 터치/키보드 → GestureStateMachine / KeyboardStateMachine → DJAction
                                                               ↓
TrackLoader → LoadedTrack → Deck → AudioEngine → DeckSnapshot / MixerSnapshot → UI
```

각 덱의 기본 오디오 경로는 다음과 같습니다.

```text
AVAudioSourceNode → low-pass EQ → master/cue path → output routing → main mixer
```

- 파일은 현재 전체 `AVAudioPCMBuffer`로 로드하지만 디코딩과 파형 계산은 백그라운드에서 수행합니다.
- 재생 위치는 렌더러만 변경하고 UI 명령은 `DeckRealtimeState`의 atomic 값과 세대 번호로 전달합니다.
- 일반 재생은 설정 템포를 사용하고, 스크래치 중에는 스크래치 속도가 재생률을 대체합니다.
- 변속 샘플 읽기에는 4-point Cubic Hermite 보간을 사용합니다.
- Equal-power 크로스페이더 중앙에서는 두 덱이 각각 약 0.707 게인입니다.

## 주요 파일

```text
Sources/TrackpadDJ/
├── App/                         앱과 윈도우 수명주기
├── input/                       DJAction, 키보드, 터치와 BPM 탭 상태
├── gestures/                    존과 결정론적 제스처 상태 머신
├── audio/                       덱, atomic 상태, 비동기 로더, 라우팅과 스냅샷
└── ui/                          입력 수신, HUD, 파형과 상태 렌더링
Tests/TrackpadDJTests/            입력·렌더·로드·라우팅·스냅샷 회귀 테스트
```

## 남은 검증과 후속 범위

가장 먼저 맥북에서 두 트랙 로드부터 전환, Split Cue 청취와 출력 장치 연결·해제까지 반복 확인해야 합니다. 그다음 감도와 존 경계를 튜닝합니다.

핫큐, 루프, 자체 트랙 브라우저, 키락, 자동 BPM 분석과 비트 싱크는 이번 마일스톤 범위가 아닙니다.

자세한 자동·수동 검증 상태는 [Docs/Verification.md](Docs/Verification.md)를 참고하세요.
