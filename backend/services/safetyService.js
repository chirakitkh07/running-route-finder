/**
 * Calculates a standard safety score from 0 to 100
 * Factors: AQI/PM2.5 (Major weight), Weather (temperature/wind - minor weight)
 * Returns { score: number, color: string, alerts: string[] }
 */
class SafetyService {
  static calculateSafetyScore(weather, airQuality) {
    let score = 100;
    const alerts = [];

    // PM2.5 Penalty (WHO guidelines)
    const pm25 = airQuality.pm2_5;
    if (pm25 > 50) { score -= 20; alerts.push("Moderate PM2.5"); }
    if (pm25 > 100) { score -= 40; alerts.push("Unhealthy PM2.5 limit reached"); }
    if (pm25 > 150) { score -= 80; alerts.push("Hazardous PM2.5 - DO NOT RUN"); }

    // Temperature Penalty
    const temp = weather.temperature;
    if (temp > 35) { score -= 20; alerts.push("Extreme Heat Warning"); }
    else if (temp < 10) { score -= 10; alerts.push("Cold Temperature Warning"); }

    // Cap score at 0 minimum
    score = Math.max(0, score);

    // Color code
    let color = 'green';
    if (score < 80) color = 'yellow';
    if (score < 50) color = 'orange';
    if (score < 20) color = 'red';

    return { score, color, alerts };
  }
}

module.exports = SafetyService;
