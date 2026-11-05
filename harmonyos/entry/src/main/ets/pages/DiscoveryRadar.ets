const PULSE_INTERVAL = 1600;

@Component
struct RadarWave {
  @Prop diameter: number = 144;
  @Prop delay: number = 0;
  @Prop spread: number = 1;
  @State private progress: number = 0;
  private startTimer: number = -1;

  private scaleFactor(): number {
    const origin = Math.min(0.5, 40 / (this.diameter - 4));
    return origin * (1 - this.progress) + this.spread * this.progress;
  }

  build() {
    Row().width(this.diameter - 4).height(this.diameter - 4).borderRadius(this.diameter / 2)
      .backgroundColor($r('app.color.radar_wave'))
      .scale({ x: this.scaleFactor(), y: this.scaleFactor() })
      .opacity(0.82 * (1 - this.progress))
      .onAppear(() => {
        this.startTimer = setTimeout(() => {
          this.getUIContext().animateTo({
            duration: PULSE_INTERVAL * 2,
            curve: Curve.Linear,
            iterations: -1,
            expectedFrameRateRange: { min: 30, max: 120, expected: 120 }
          }, () => { this.progress = 1; });
        }, this.delay + 32);
      })
      .onDisAppear(() => clearTimeout(this.startTimer))
  }
}

@Component
struct RadarSignal {
  @State private pulse: number = 0;
  private startTimer: number = -1;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Image($r('app.media.nearby_signal')).width(46).height(46)
        .scale({ x: 0.88 + 0.16 * this.pulse, y: 0.88 + 0.16 * this.pulse })
        .opacity(1 - 0.72 * this.pulse)
      Row().width(7).height(7).borderRadius(4).backgroundColor($r('app.color.radar_signal'))
    }.width(48).height(48)
      .onAppear(() => {
        this.startTimer = setTimeout(() => {
          this.getUIContext().animateTo({
            duration: PULSE_INTERVAL / 2,
            curve: Curve.EaseInOut,
            playMode: PlayMode.Alternate,
            iterations: -1,
            expectedFrameRateRange: { min: 30, max: 120, expected: 120 }
          }, () => { this.pulse = 1; });
        }, 32);
      })
      .onDisAppear(() => clearTimeout(this.startTimer))
  }
}

@Component
export struct DiscoveryRadar {
  @Prop areaHeight: string = '100%';
  @State private diameter: number = 280;
  @State private spread: number = 1.7;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      RadarWave({ diameter: this.diameter, spread: this.spread })
      RadarWave({ diameter: this.diameter, spread: this.spread, delay: PULSE_INTERVAL })
      RadarSignal()
    }.width('100%').height(this.areaHeight).hitTestBehavior(HitTestMode.None)
      .onAreaChange((_previous, area) => {
        const width = Number.parseFloat(String(area.width));
        const height = Number.parseFloat(String(area.height));
        if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 4 || height <= 4) return;
        this.diameter = Math.min(width, height);
        this.spread = Math.hypot(width, height) / this.diameter * 1.18;
      })
  }
}
