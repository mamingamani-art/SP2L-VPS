# SP2L VPS Package

This repository contains the SP2L MetaTrader 5 VPS package, including the compiled Expert Advisor (`.ex5`), preset files (`.set`), and Persian installation notes.

## Included files

- `SP2L_Advanced_Optimized_M5.mq5` — MQL5 source for the VPS Expert Advisor.
- `SP2L_Advanced_Optimized_M5.ex5` — compiled MT5 Expert Advisor, used by the XAUUSD and US30 presets.
- `SP2L_M5_Robust_Selected_17M.set` — XAUUSD M5 preset.
- `SP2L_US30_M5_Robust_Selected.set` — US30 M5 preset.
- `SP2L_US500_M5/SP2L_US500_M5_Robust_Selected.set` — US500 M5 preset included in the source package.
- `SP2L_VPS_INSTALL_FA.txt` — installation guide in Persian.

The duplicate copy of the compiled EA from the original nested folder is omitted; the top-level binary is the same package artifact. The included `.mq5` source has the same basename as the VPS `.ex5`; its compiled output matches the binary included here.

## Installation

Follow `SP2L_VPS_INSTALL_FA.txt`. Test on a demo account before using a live account. Preset files contain strategy parameters, including lot sizes; review them carefully before enabling Algo Trading.

## Notice

This repository distributes compiled trading software and configuration presets. It does not guarantee performance or returns. Use at your own risk. No license is specified.
