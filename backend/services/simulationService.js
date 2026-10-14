const WeatherService = require('./weatherService');
const AirService = require('./airService');
const SafetyService = require('./safetyService');

class SimulationService {
  /**
   * Simulate environmental and safety conditions for a run
   * @param {number} lat 
   * @param {number} lng 
   * @returns {Promise<Object>}
   */
  async simulatePreRun(lat, lng) {
    if (!lat || !lng) {
      throw new Error('Missing lat or lng parameters');
    }

    // Parallel fetch for speed constraints (requirement: within 2 seconds)
    const [weather, airQuality] = await Promise.all([
      WeatherService.getCurrentWeather(lat, lng),
      AirService.getCurrentAirQuality(lat, lng)
    ]);

    const safetyFeedback = SafetyService.calculateSafetyScore(weather, airQuality);

    // Mock Elevation and Time estimation (these would normally come from Routing services)
    const mockSimulation = {
      estimatedTimeMinutes: 30,
      elevationProfile: [10, 15, 20, 15, 10], // Sample elevation points in meters
      difficulty: 'Easy'
    };

    return {
      location: { lat, lng },
      weather,
      airQuality,
      safety: safetyFeedback,
      simulation: mockSimulation
    };
  }
}

module.exports = new SimulationService();
