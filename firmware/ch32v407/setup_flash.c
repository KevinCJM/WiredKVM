/* Prototype SPI1 mapping: PA4 CS, PA5 SCK, PA6 MISO, PA7 MOSI.
 * Read commands only; no write-enable, erase, program or status-register write.
 * Final PCB pin allocation must be verified with the USB/power schematic. */
#include "ch32v4x7.h"
#include "setup_flash.h"
static bool available;
static bool exchange(uint8_t in,uint8_t *out) {
    unsigned limit=10000;
    while(SPI_I2S_GetFlagStatus(SPI1,SPI_I2S_FLAG_TXE)==RESET)if(!--limit)return false;
    SPI_I2S_SendData(SPI1,in);limit=10000;
    while(SPI_I2S_GetFlagStatus(SPI1,SPI_I2S_FLAG_RXNE)==RESET)if(!--limit)return false;
    *out=(uint8_t)SPI_I2S_ReceiveData(SPI1);return true;
}
bool wk_setup_flash_init(void) {
    RCC_PB2PeriphClockCmd(RCC_PB2Periph_GPIOA|RCC_PB2Periph_SPI1,ENABLE);
    GPIO_InitTypeDef gpio={0};gpio.GPIO_Pin=GPIO_Pin_4;gpio.GPIO_Speed=GPIO_Speed_High;gpio.GPIO_Mode=GPIO_Mode_Out_PP;
    GPIO_Init(GPIOA,&gpio);GPIO_SetBits(GPIOA,GPIO_Pin_4);
    gpio.GPIO_Pin=GPIO_Pin_5|GPIO_Pin_7;gpio.GPIO_Mode=GPIO_Mode_AF_PP;GPIO_Init(GPIOA,&gpio);
    gpio.GPIO_Pin=GPIO_Pin_6;gpio.GPIO_Mode=GPIO_Mode_IN_FLOATING;GPIO_Init(GPIOA,&gpio);
    SPI_InitTypeDef spi={0};spi.SPI_Direction=SPI_Direction_2Lines_FullDuplex;spi.SPI_Mode=SPI_Mode_Master;
    spi.SPI_DataSize=SPI_DataSize_8b;spi.SPI_CPOL=SPI_CPOL_Low;spi.SPI_CPHA=SPI_CPHA_1Edge;
    spi.SPI_NSS=SPI_NSS_Soft;spi.SPI_BaudRatePrescaler=SPI_BaudRatePrescaler_4;spi.SPI_FirstBit=SPI_FirstBit_MSB;spi.SPI_CRCPolynomial=7;
    SPI_Init(SPI1,&spi);SPI_Cmd(SPI1,ENABLE);
    uint8_t ignored,id[3];GPIO_ResetBits(GPIOA,GPIO_Pin_4);
    bool ok=exchange(0x9f,&ignored);
    for(unsigned i=0;i<3&&ok;i++)ok=exchange(0xff,id+i);
    GPIO_SetBits(GPIOA,GPIO_Pin_4);
    available=ok&&id[0]!=0&&id[0]!=0xff&&id[2]>=22&&id[2]<=26;return available;
}
bool wk_setup_flash_read(void *context,uint32_t address,void *bytes,size_t n) {
    (void)context;
    if(!available||address>WK_SETUP_FLASH_BYTES||n>512||n>WK_SETUP_FLASH_BYTES-address)return false;
    uint8_t ignored;GPIO_ResetBits(GPIOA,GPIO_Pin_4);bool ok=exchange(3,&ignored);
    for(unsigned i=0;i<3&&ok;i++)ok=exchange((uint8_t)(address>>(16-i*8)),&ignored);
    uint8_t *out=bytes;for(size_t i=0;i<n&&ok;i++)ok=exchange(0xff,out+i);
    GPIO_SetBits(GPIOA,GPIO_Pin_4);return ok;
}
