class WeatherService {
  static async getCurrentWeather(lat, lng) {
    try {
      const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lng}&current_weather=true`;
      const response = await fetch(url);
      
      if (!response.ok) throw new Error('Failed to fetch weather data');
      const data = await response.json();
      
      return {
        temperature: data.current_weather.temperature,
        windspeed: data.current_weather.windspeed,
        weathercode: data.current_weather.weathercode,
        time: data.current_weather.time
      };
    } catch (error) {
      console.error(error);
      throw new Error('WeatherService Error: ' + error.message);
    }
  }
}

module.exports = WeatherService;
