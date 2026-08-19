# Trackpad DJ 검증 기록

## 안정화 마일스톤 결과

2026-08-19 로컬 소스 기준이다. 자동 검증과 화면 관찰은 PASS지만, 실제 트랙패드 조작성과 오디오 청취는 별도 `UNVERIFIED`다.

| 구분 | 결과 | 증거와 범위 |
|---|---|---|
| `Scripts/verify-build.sh` | PASS | Debug 실행 파일 빌드 |
| `swift test` | PASS | 31 tests, 0 failures |
| `Scripts/verify-strict-concurrency.sh` | PASS | `-strict-concurrency=complete -warnings-as-errors` 실행 타깃 빌드 |
| 결정론적 제스처 trace | PASS | 대각선, 존 이탈, 멀티터치, 50ms 정지와 취소 이벤트 |
| atomic 렌더 명령 | PASS | 최신 탐색 명령 1회 소비, 재생 끝 클램프, 템포·스크래치 복귀와 경합 |
| 비동기 로드 | PASS | 실패 시 기존 트랙 유지, 이전 요청 지연 완료 무시, 설치 시 상태 초기화 |
| 템포 / 크로스페이더 | PASS | ±8% 클램프, 0.05% 키 반복, Equal-power 끝점과 중앙 약 0.707 |
| Split Cue 합성 신호 | PASS | 오프라인 렌더에서 왼쪽 Master 0.25, 오른쪽 Cue 0.50, 반대 채널 누설 없음 |
| Split Cue 그래프 | PASS | 8kHz mono Deck A와 16kHz stereo Deck B 동시 설치, 모드 재전환과 멱등 종료 |
| 데스크톱 UI 관찰 | PASS | 초기 화면, 상단 Split Cue 경고, Deck A `MON` 표시를 실제 앱 창 스크린샷으로 확인 |
| 시스템 단축키 | PASS | `⌘Q`가 Deck A 로드를 열지 않고 Split Cue 상태 앱을 종료 코드 0으로 종료 |

WAV fixture 로드 중 AVFAudio가 비인터리브 설정을 무시한다는 진단 메시지가 출력되지만 테스트와 디코딩은 성공한다. 이를 실제 장치 음질 증거로 사용하지 않는다.

## 실기기 체크리스트

아래 항목은 이번 자동화 세션에서 수행하지 못했으며 모두 `UNVERIFIED`다.

- [ ] 실제 음악 두 곡 로드 → 큐 → 재생 → 템포 → 볼륨·필터 → 크로스페이드
- [ ] 트랙패드 수직 스크래치와 수평 필터의 감도·레이턴시·클릭 노이즈
- [ ] 대각선 입력, 존 경계 이탈과 터치 취소 후 프리즈 해제
- [ ] 헤드폰 왼쪽에서 Master만, 오른쪽에서 선택한 Cue만 청취
- [ ] `C`/`V` 프리큐 토글 중 왼쪽 Master 음량 불변
- [ ] 두 덱 동시 프리큐의 헤드룸과 체감 음량
- [ ] 헤드폰 또는 출력 장치 연결·해제 후 안전한 복구와 프리큐 무유출
- [ ] 30분 연속 믹싱 중 클릭, 멈춤, 잘못된 키 고정과 상태 누적 없음

실기기 검증 시 사용한 오디오 장치, macOS 버전, 트랙 형식·샘플레이트와 관찰 결과를 함께 기록한다. 빌드 성공이나 합성 신호 PASS만으로 이 체크박스를 완료 처리하지 않는다.

## 작업 전 기준선

안정화 작업 시작 전인 2026-08-19의 상태다.

| 확인 | 결과 | 당시 증거 |
|---|---|---|
| `Scripts/verify-build.sh` | PASS | Debug 실행 파일 빌드 성공 |
| `swift test --build-path .build-test-baseline` | FAIL | SwiftPM `no tests found` |
| `Scripts/verify-strict-concurrency.sh` | FAIL | `TouchLabView`와 `TouchLabViewController` 타이머의 main-actor 오류 |

당시에는 미연결 핫큐 키·마커, 동기 트랙 로드, UI와 렌더 콜백의 직접 공유 상태가 남아 있었다. 현재는 미연결 핫큐 표면을 제거하고 비동기 로드, atomic 실시간 경계와 자동 테스트로 교체했다.
