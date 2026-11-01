;
; projeto_1_micro.asm
;
; Autores:
; Jackson Bruno Lima Leão
; Pedro Henrique Santos Resende
; Thiago Ribeiro da Silva
; Willian Tcheldon Oliveira Santos


; Mapeamento:
; Semáforo 0 (Pedestre): PD0 (Vermelho = 0, Verde = 1)
; Semáforo 1: PD7 (Vermelho) PD6 (Amarelo) PD5 (Verde)
; Semáforo 2: PB2 (Vermelho) PB1 (Amarelo) PB0 (Verde)
; Semáforo 3: PB5 (Vermelho) PB4 (Amarelo) PB3 (Verde)
; Semáforo 4: PD4 (Vermelho) PD3 (Amarelo) PD2 (Verde)
; 2 BCDs: PC0 (S0) PC1 (S1) PC2 (S2) PC3 (S3) PC4 (OE BCD1) PC5 (OE BCD2)
; Serial (USART0): PD1 (TX), 9600 baud, 8N1, transmissão por interrupção
; (UDRE). Envia uma linha de texto a cada mudança de estado.
; O programa assume displays multiplexados, OE ativo em zero,
; LEDs acesos com nivel alto e clock de 16 MHz.

; Definição de Constantes
.equ N_ESTADOS = 11 
#define CLOCK 16.0e6 ; clock
#define DELAY 5.0e-3 ; 5 ms
.equ PRESCALE = 0b011 ; /64 prescale
.equ PRESCALE_DIV = 64
.equ WGM = 0b0100 ; Modo CTC (Clear to Compare)
.equ TOP = int(0.5 + ((CLOCK/PRESCALE_DIV)*DELAY))
;16 mhz clock speed, 9600 baud UBRR = 103
.equ UBRR_VAL = 103
.equ TAM_BUFFER_TX = 80 ; uma linha tem 79 caracteres + o 0 do fim

; Validação do valor TOP (precisa ser <= 2 bytes)
.if TOP > 65535
.error "TOP está fora do limite permitido"
.endif

; Nomeação de registradores
.def temp      = r16
.def estado    = r17
.def duracao   = r18
.def cont_s3   = r19
.def unidade   = r20
.def dezena    = r21
.def cont_5ms  = r22
.def mux       = r23
.def caractere = r24

; Memória de dados (SRAM): buffer com a linha de texto a ser enviada
.dseg
BUFFER_TX: .byte TAM_BUFFER_TX

.cseg

; Inicialização dos vetores de interrupção
jmp RESET
.org OC1Aaddr
jmp TIMER1_COMPA_ISR
.org UDREaddr
jmp USART_UDRE_ISR

RESET:
	; Inicialização da pilha
	ldi temp, low(RAMEND)
	out SPL, temp
	ldi temp, high(RAMEND)
	out SPH, temp

	; configura como saída os pinos usados pros LEDs e Displays
	ldi temp, $FF
	out DDRB, temp
	ldi temp, 0b11111101
	out DDRD, temp
	ldi temp, 0b00111111
	out DDRC, temp

	; incializa contador de 1s (200 * 5ms) e o
	; registrador de multiplexação
	ldi cont_5ms, 200
	clr mux

	; programa começando no estado 0
	ldi estado, 0
	rcall CARREGA_ESTADO

	; habilita interrupção de timer
	lds	 temp, TIMSK1
	sbr temp, 1<<OCIE1A
	sts TIMSK1, temp

	; Configurações de inicialização do Timer 1 com duração de 5ms

	; inicializa o valor de comparação do Timer 1 (TOP)
	ldi temp, high(TOP)
	sts OCR1AH, temp
	ldi temp, low(TOP)
	sts OCR1AL, temp

	; define modo CTC e Prescale = 64
	ldi temp, ((WGM&0b11) << WGM10) ;lower 2 bits of WGM
	; WGM&0b11 = 0b0100 & 0b0011 = 0b0000 
	sts TCCR1A, temp
	ldi temp, ((WGM>> 2) << WGM12)|(PRESCALE << CS10)
	; WGM >> 2 = 0b0100 >> 2 = 0b0001
	; (WGM >> 2) << WGM12 = (0b0001 << 3) = 0b0001000
	; (PRESCALE << CS10) = 0b011 << 0 = 0b011
	; 0b0001000 | 0b011 = 0b0001011
	sts TCCR1B, temp ; inicia timer

	; Inicializa USART
	ldi temp, high(UBRR_VAL)
	sts UBRR0H, temp
	ldi temp, low(UBRR_VAL)
	sts UBRR0L, temp

	;8 bits, 1 stop, no parity
	ldi temp, (3<<UCSZ00)
	sts UCSR0C, temp
	; habilita só o transmissor
	ldi temp, (1<<TXEN0)
	sts UCSR0B, temp

	sei ; ativa flag de interrupção global

	rcall MONTA_MENSAGEM

	LOOP_PRINCIPAL:
		rjmp LOOP_PRINCIPAL

TIMER1_COMPA_ISR:
	; Interrupções a cada 5ms. Faz a multiplexação dos displays
	; a cada interrupção e, a cada 200 interrupções (200 * 5ms = 1s),
	; atualiza os dados da maquina de estados

	; armazena SREG e temp na pilha
	push temp
	in temp, SREG
	push temp

	rcall MULTIPLEXA

	dec cont_5ms
	brne FINALIZA_ISR
	ldi cont_5ms, 200

	; decrementa duração do estado
	dec duracao
	; quando duracao = 0, muda estado
	breq MUDANCA_ESTADO
	; decrementa duração até mudança de cor no Semáforo 3
	dec cont_s3
	rcall ATUALIZA_VALOR_DISPLAY
	rjmp FINALIZA_ISR

	MUDANCA_ESTADO:
		inc estado
		; quando estado = N_ESTADO, estado = 0
		cpi estado, N_ESTADOS
		brne FINALIZA_MUDANCA
		ldi estado, 0
		; carrega estado atual e volta para finalizar o ISR
		FINALIZA_MUDANCA:
			rcall CARREGA_ESTADO
			; monta a linha do novo estado e inicia o envio pela serial
			rcall MONTA_MENSAGEM
			rjmp FINALIZA_ISR

USART_UDRE_ISR:
	; Interrupção "USART Data Register Empty": o UDR0 está livre.
	; Envia o próximo caractere do BUFFER_TX; se for o 0 do fim,
	; desliga a interrupção (senão ela continuaria disparando, já que
	; o UDR0 continua vazio).
	;
	; Entrada: Y apontando para o próximo caractere do BUFFER_TX
	push temp
	in temp, SREG
	push temp

	ld temp, Y+
	tst temp
	breq USART_UDRE_FIM
	sts UDR0, temp          ; envia o caractere
	rjmp FINALIZA_ISR

	USART_UDRE_FIM:
		; fim da mensagem: desliga a interrupção UDRE
		lds temp, UCSR0B
		cbr temp, (1<<UDRIE0)
		sts UCSR0B, temp

FINALIZA_ISR:
	; retoma valor de SREG
	pop temp
	out SREG, temp
	pop temp
	reti

CARREGA_ESTADO:
	; lê a linha do estado atual na TABELA_ESTADOS, acende os leds e
	; carrega a duração e contador do semáforo 3
	;
	; Entrada: estado (0 a N_ESTADOS - 1)
	; Saída: PORTB, PORTD, duracao, cont_s3, unidade, dezena

	ldi ZL, low(TABELA_ESTADOS*2)
	ldi ZH, high(TABELA_ESTADOS*2)
	mov temp, estado
	; Cada estado tem 4 bytes, então, multiplicamos estado * 4 e somamos
	; ao endereço inicial da tabela para pegar os dados do estado atual
	lsl temp
	lsl temp
	add ZL, temp
	clr temp
	adc ZH, temp
	; 1ª byte: configuração do estado em PORTB
	lpm temp, Z+
	out PORTB, temp
	; 2ª byte: configuração do estado em PORTD
	lpm temp, Z+
	out PORTD, temp
	; 3ª byte: duração do estado
	lpm duracao, Z+
	; 4ª byte: duração até mudança de cor no Semáforo 3 (display)
	lpm cont_s3, Z+
	; Atualiza valor do display com cont_s3 novo
	rcall ATUALIZA_VALOR_DISPLAY
	ret

ATUALIZA_VALOR_DISPLAY:
	; Atualiza valores de dezena e unidade usados no display
	; com o valor atual de cont_s3
	;
	; Entrada: cont_s3
	; Saída: unidade, dezena
	mov temp, cont_s3
	clr dezena
	CONVERTE_DEZENAS:
		cpi temp, 10
		brlo FIM_CONVERSAO
		subi temp, 10
		inc dezena
		rjmp CONVERTE_DEZENAS
	FIM_CONVERSAO:
		mov unidade, temp
		ret

MULTIPLEXA:
	; alterna o dígito exibido a cada chamada (5ms). Escreve o valor BCD
	; em PC0-3 e habilita o OE do display correspondente (OE ativo em
	; nível baixo)
	;
	; Os displays começam habilitados (0E = 0) e são desabilitados
	; quando o outro precisa receber o valor BCD
	;
	; Entrada: mux (0 = dezena, 1 = unidade), dezena, unidade
	; Saída: PORTC, ~mux
	tst mux
	brne MOSTRA_UNIDADE
	MOSTRA_DEZENA:
		mov temp, dezena
		; Desabilita OE do Display 1 (Unidade)
		ori temp, (1<<PC4)
		ldi mux, 1
		rjmp ESCREVE
	MOSTRA_UNIDADE:
		mov temp, unidade
		; Desabilita OE do Display 2 (Dezena)
		ori temp, (1<<PC5)
		clr mux
	ESCREVE:
		out PORTC, temp
		ret

MONTA_MENSAGEM:
	; Escreve no BUFFER_TX a linha de texto do estado atual e liga a
	; interrupção UDRE para começar o envio. As cores são lidas direto
	; de PORTB e PORTD, então o texto mostra exatamente o que está aceso
	; nos LEDs.
	;
	; Entrada: estado, duracao, PORTB, PORTD
	; Saída: BUFFER_TX, Y (início do buffer), UDRIE0 = 1

	; X aponta para onde o próximo caractere será escrito no buffer
	ldi XL, low(BUFFER_TX)
	ldi XH, high(BUFFER_TX)

	; "Estado " + número do estado (estado + 1, igual à TABELA_ESTADOS)
	ldi ZL, low(TXT_ESTADO*2)
	ldi ZH, high(TXT_ESTADO*2)
	rcall COPIA_TEXTO
	mov temp, estado
	inc temp
	rcall ESCREVE_NUMERO

	; Semáforo 0 (pedestre): PD0 = 1 -> verde, PD0 = 0 -> vermelho
	ldi ZL, low(TXT_S0*2)
	ldi ZH, high(TXT_S0*2)
	rcall COPIA_TEXTO
	ldi temp, 0b100          ; vermelho
	sbic PORTD, PD0          ; se PD0 = 1...
	ldi temp, 0b001          ; ...verde
	rcall ESCREVE_COR

	; Para os semáforos 1 a 4, os 3 bits de cada um são deslocados para
	; as posições 2 (vermelho), 1 (amarelo) e 0 (verde) de temp

	; Semáforo 1: PD7 PD6 PD5 -> desloca PORTD 5 bits para a direita
	ldi ZL, low(TXT_S1*2)
	ldi ZH, high(TXT_S1*2)
	rcall COPIA_TEXTO
	in temp, PORTD
	lsr temp
	lsr temp
	lsr temp
	lsr temp
	lsr temp
	rcall ESCREVE_COR

	; Semáforo 2: PB2 PB1 PB0 -> já estão nas posições certas
	ldi ZL, low(TXT_S2*2)
	ldi ZH, high(TXT_S2*2)
	rcall COPIA_TEXTO
	in temp, PORTB
	rcall ESCREVE_COR

	; Semáforo 3: PB5 PB4 PB3 -> desloca PORTB 3 bits para a direita
	ldi ZL, low(TXT_S3*2)
	ldi ZH, high(TXT_S3*2)
	rcall COPIA_TEXTO
	in temp, PORTB
	lsr temp
	lsr temp
	lsr temp
	rcall ESCREVE_COR

	; Semáforo 4: PD4 PD3 PD2 -> desloca PORTD 2 bits para a direita
	ldi ZL, low(TXT_S4*2)
	ldi ZH, high(TXT_S4*2)
	rcall COPIA_TEXTO
	in temp, PORTD
	lsr temp
	lsr temp
	rcall ESCREVE_COR

	; duração do estado: "(" + segundos + " s)" + quebra de linha
	ldi ZL, low(TXT_DUR_INI*2)
	ldi ZH, high(TXT_DUR_INI*2)
	rcall COPIA_TEXTO
	mov temp, duracao
	rcall ESCREVE_NUMERO
	ldi ZL, low(TXT_DUR_FIM*2)
	ldi ZH, high(TXT_DUR_FIM*2)
	rcall COPIA_TEXTO

	; 0 no fim do buffer marca o fim da mensagem
	clr caractere
	st X, caractere

	; Y volta para o início do buffer e a interrupção UDRE é ligada.
	; Como o UDR0 já está livre, ela dispara logo em seguida e começa
	; a enviar a mensagem.
	ldi YL, low(BUFFER_TX)
	ldi YH, high(BUFFER_TX)
	lds temp, UCSR0B
	sbr temp, (1<<UDRIE0)
	sts UCSR0B, temp
	ret

ESCREVE_COR:
	; Escreve no buffer o nome da cor acesa de um semáforo
	;
	; Entrada: temp com bit 2 = vermelho, bit 1 = amarelo, bit 0 = verde
	; (os outros bits são ignorados), X
	ldi ZL, low(TXT_VERMELHO*2)
	ldi ZH, high(TXT_VERMELHO*2)
	sbrc temp, 2
	rjmp ESCREVE_COR_FIM
	ldi ZL, low(TXT_AMARELO*2)
	ldi ZH, high(TXT_AMARELO*2)
	sbrc temp, 1
	rjmp ESCREVE_COR_FIM
	ldi ZL, low(TXT_VERDE*2)
	ldi ZH, high(TXT_VERDE*2)
	sbrc temp, 0
	rjmp ESCREVE_COR_FIM
	ldi ZL, low(TXT_APAGADO*2)
	ldi ZH, high(TXT_APAGADO*2)
	ESCREVE_COR_FIM:
		rcall COPIA_TEXTO
		ret

ESCREVE_NUMERO:
	; Escreve no buffer um número de 0 a 99 como 2 dígitos ASCII
	; (ex.: 7 -> "07"). Somar '0' (48) converte o dígito em ASCII.
	;
	; Entrada: temp (0 - 99), X
	ldi caractere, '0'
	ESCREVE_NUMERO_DEZENAS:
		cpi temp, 10
		brlo ESCREVE_NUMERO_FIM
		subi temp, 10
		inc caractere
		rjmp ESCREVE_NUMERO_DEZENAS
	ESCREVE_NUMERO_FIM:
		st X+, caractere        ; dezena
		mov caractere, temp
		subi caractere, -'0'    ; soma '0' (o AVR não tem addi)
		st X+, caractere        ; unidade
		ret

COPIA_TEXTO:
	; Copia um texto da memória de programa (flash) para o buffer
	; (SRAM), até encontrar o byte 0 (fim do texto). O 0 não é copiado.
	;
	; Entrada: Z apontando para o texto (endereço * 2), X
	lpm caractere, Z+
	tst caractere
	breq COPIA_TEXTO_FIM
	st X+, caractere
	rjmp COPIA_TEXTO
	COPIA_TEXTO_FIM:
		ret

TABELA_ESTADOS:
;   PORTB       PORTD      dur  S3 (tempo até mudança de cor no S3)
.db 0b00100100, 0b10010001, 12, 14     ; E1: pedestre verde
.db 0b00100100, 0b10010000,  2,  2     ; E2: todos vermelhos
.db 0b00001001, 0b10010000, 22, 88     ; E3: S2 e S3 verdes
.db 0b00001010, 0b10010000,  4, 66     ; E4: S2 amarelo, S3 verde
.db 0b00001100, 0b10010000,  1, 62     ; E5: S3 verde
.db 0b00001100, 0b10000100, 61, 61     ; E6: S3 e S4 verdes
.db 0b00010100, 0b10001000,  4,	 4     ; E7: S3 e S4 amarelos
.db 0b00100100, 0b10010000,  1, 45     ; E8: todos vermelhos
.db 0b00100100, 0b00110000, 25, 44     ; E9: S1 verde
.db 0b00100100, 0b01010000,  4, 19     ; E10: S1 amarelo
.db 0b00100100, 0b10010000,  1, 15     ; E11: todos vermelhos

; Textos enviados pela serial (terminados em 0). Cada linha .db tem um
; número par de bytes, porque a memória de programa é organizada em
; palavras (2 bytes). As cores têm 9 caracteres para ficarem alinhadas.
TXT_ESTADO:   .db "Estado ", 0
TXT_S0:       .db ": S0=", 0
TXT_S1:       .db "S1=", 0
TXT_S2:       .db "S2=", 0
TXT_S3:       .db "S3=", 0
TXT_S4:       .db "S4=", 0
TXT_DUR_INI:  .db "(", 0
TXT_DUR_FIM:  .db " s)", 13, 10, 0   ; 13, 10 = \r\n (quebra de linha)
TXT_VERMELHO: .db "VERMELHO ", 0
TXT_AMARELO:  .db "AMARELO  ", 0
TXT_VERDE:    .db "VERDE    ", 0
TXT_APAGADO:  .db "APAGADO  ", 0