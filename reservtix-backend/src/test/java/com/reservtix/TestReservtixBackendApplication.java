package com.reservtix;

import org.springframework.boot.SpringApplication;

public class TestReservtixBackendApplication {

	public static void main(String[] args) {
		SpringApplication.from(ReservtixBackendApplication::main).with(TestcontainersConfiguration.class).run(args);
	}

}
