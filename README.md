# ScrollBar

macOS 메뉴바에 LED 전광판 스타일로 실시간 경제지표를 스크롤 표시하는 앱.

신칸센 전광판에서 영감을 받아, 도트 매트릭스 렌더링으로 진짜 LED 느낌을 구현했습니다.

## Features

- **LED 도트 매트릭스** - Core Graphics로 각 픽셀을 둥근 LED 도트로 렌더링
- **실시간 경제지표** - KOSPI, KOSDAQ, DOW, NASDAQ, S&P500, USD/KRW, JPY/KRW, 오름테라퓨틱
- **컬러 LED** - 상승 🔴 빨간색 / 하락 🔵 파란색 / 종목명 ⚪ 흰색
- **글로우 효과** - 켜진 LED에 2단계 발광 + 중심 하이라이트
- **Launch at Login** - 로그인 시 자동 시작 지원
- **Dock 아이콘 없음** - LSUIElement로 메뉴바 전용

## Build

```bash
# 빌드 + .app 번들 생성
./build-app.sh

# 실행
open ScrollBar.app

# /Applications에 설치
./build-app.sh --install
```

### Requirements

- macOS 13.0+
- Swift 5.9+

## Menu Options

메뉴바 클릭 시:
- **Refresh** - 데이터 수동 새로고침 (자동 60초 간격)
- **Speed** - Slow / Normal / Fast / Turbo
- **Width** - Normal (350) / Wide (450) / Extra Wide (550)
- **Launch at Login** - 로그인 시 자동 시작
- **Quit** - 종료

## Data Source

Yahoo Finance API를 통해 실시간 시세를 가져옵니다.

## License

MIT
