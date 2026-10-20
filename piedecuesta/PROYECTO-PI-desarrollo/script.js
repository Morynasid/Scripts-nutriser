/*=========================================================
    FORTKORP
    SCRIPT.JS
    PARTE 1
=========================================================*/

/*=========================================
        MENÚ RESPONSIVE
=========================================*/

const menu = document.querySelector(".menu");
const menuMovil = document.querySelector(".menuMovil");

menuMovil.addEventListener("click", () => {

    menu.classList.toggle("activo");

});

/*=========================================
        CAMBIO NAVBAR
=========================================*/

const navbar = document.querySelector("header");

window.addEventListener("scroll", () => {

    if(window.scrollY > 80){

        navbar.style.background = "#05070D";

        navbar.style.boxShadow = "0 10px 30px rgba(0,191,255,.18)";

    }

    else{

        navbar.style.background = "rgba(5,7,13,.90)";

        navbar.style.boxShadow = "none";

    }

});

/*=========================================
        BOTÓN SUBIR
=========================================*/

const subir = document.querySelector(".subir");

window.addEventListener("scroll",()=>{

    if(window.scrollY > 500){

        subir.style.opacity="1";
        subir.style.pointerEvents="auto";

    }

    else{

        subir.style.opacity="0";
        subir.style.pointerEvents="none";

    }

});

/*=========================================================
        PARTE 2
        CARRUSEL SERVICIOS
=========================================================*/

const slider = document.querySelector(".contenedorSlider");
const btnIzquierda = document.querySelector(".izquierda");
const btnDerecha = document.querySelector(".derecha");

const mover = 350;

/*==========================
        BOTONES
===========================*/

btnDerecha.addEventListener("click",()=>{

    slider.scrollBy({

        left:mover,

        behavior:"smooth"

    });

});

btnIzquierda.addEventListener("click",()=>{

    slider.scrollBy({

        left:-mover,

        behavior:"smooth"

    });

});

/*==========================
      AUTO SLIDE
===========================*/

setInterval(()=>{

    if(

        slider.scrollLeft + slider.clientWidth

        >= slider.scrollWidth - 10

    ){

        slider.scrollTo({

            left:0,

            behavior:"smooth"

        });

    }

    else{

        slider.scrollBy({

            left:mover,

            behavior:"smooth"

        });

    }

},4000);

/*==========================
 PAUSAR CUANDO EL MOUSE ESTÁ ENCIMA
===========================*/

let intervaloServicios;

function iniciarServicios(){

    intervaloServicios = setInterval(()=>{

        if(slider.scrollLeft + slider.clientWidth >= slider.scrollWidth-10){

            slider.scrollTo({

                left:0,

                behavior:"smooth"

            });

        }

        else{

            slider.scrollBy({

                left:mover,

                behavior:"smooth"

            });

        }

    },4000);

}

function detenerServicios(){

    clearInterval(intervaloServicios);

}

detenerServicios();

iniciarServicios();

slider.addEventListener("mouseenter",detenerServicios);

slider.addEventListener("mouseleave",iniciarServicios);
/*=========================================================
        PARTE 3
        CARRUSEL PERSONAL
=========================================================*/

const sliderPersonal = document.querySelector(".sliderPersonal");

const btnPersonalIzq = document.querySelector(".izquierdaPersonal");

const btnPersonalDer = document.querySelector(".derechaPersonal");

const moverPersonal = 350;

/*==========================
      BOTÓN DERECHA
===========================*/

btnPersonalDer.addEventListener("click",()=>{

    sliderPersonal.scrollBy({

        left:moverPersonal,

        behavior:"smooth"

    });

});

/*==========================
      BOTÓN IZQUIERDA
===========================*/

btnPersonalIzq.addEventListener("click",()=>{

    sliderPersonal.scrollBy({

        left:-moverPersonal,

        behavior:"smooth"

    });

});

/*==========================
      AUTO CARRUSEL
===========================*/

let intervaloPersonal;

function iniciarPersonal(){

    intervaloPersonal = setInterval(()=>{

        if(

            sliderPersonal.scrollLeft +

            sliderPersonal.clientWidth >=

            sliderPersonal.scrollWidth-10

        ){

            sliderPersonal.scrollTo({

                left:0,

                behavior:"smooth"

            });

        }

        else{

            sliderPersonal.scrollBy({

                left:moverPersonal,

                behavior:"smooth"

            });

        }

    },3500);

}

function detenerPersonal(){

    clearInterval(intervaloPersonal);

}

iniciarPersonal();

sliderPersonal.addEventListener("mouseenter",detenerPersonal);

sliderPersonal.addEventListener("mouseleave",iniciarPersonal);
/*=========================================================
        CONTADORES
=========================================================*/

const numeros = document.querySelectorAll(".dato h2");

const velocidad = 80;

numeros.forEach(numero=>{

    const actualizar=()=>{

        const objetivo=+numero.innerText.replace("+","").replace("%","");

        const actual=+numero.getAttribute("data-contador")||0;

        const incremento=Math.ceil(objetivo/velocidad);

        if(actual<objetivo){

            const nuevo=actual+incremento;

            numero.setAttribute("data-contador",nuevo);

            if(numero.innerText.includes("%")){

                numero.innerText=nuevo+"%";

            }else{

                numero.innerText="+"+nuevo;

            }

            setTimeout(actualizar,25);

        }

        else{

            if(numero.innerText.includes("%")){

                numero.innerText=objetivo+"%";

            }else{

                numero.innerText="+"+objetivo;

            }

        }

    }

    actualizar();

});
/*=========================================================
        SCROLL REVEAL
=========================================================*/

const elementos=document.querySelectorAll(

".objetivoCard,.mvCard,.servicioCard,.cardAtencion,.beneficio,.cardPersonal,.dato"

);

const revelar=()=>{

    elementos.forEach(el=>{

        const posicion=el.getBoundingClientRect().top;

        const pantalla=window.innerHeight;

        if(posicion<pantalla-120){

            el.style.opacity="1";

            el.style.transform="translateY(0px)";

        }

    });

}

elementos.forEach(el=>{

    el.style.opacity="0";

    el.style.transform="translateY(80px)";

    el.style.transition=".8s";

});

window.addEventListener("scroll",revelar);

revelar();
