FROM eclipse-temurin:17-jre-jammy
WORKDIR /app
ARG MODULE
COPY ${MODULE}/target/${MODULE}-0.1.0.jar /app/app.jar
USER 10001
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
