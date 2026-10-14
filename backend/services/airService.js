class AirService {
  static async getCurrentAirQuality(lat, lng) {
    try {
      const url = `https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${lat}&longitude=${lng}&current=pm2_5,aqi`;
      const response = await fetch(url);
      
      if (!response.ok) throw new Error('Failed to fetch air quality data');
      const data = await response.json();
      
      return {
        pm2_5: data.current.pm2_5,
        aqi: data.current.aqi,
        time: data.current.time
      };
    } catch (error) {
      console.error(error);
      throw new Error('AirService Error: ' + error.message);
    }
  }
}

module.exports = AirService;
