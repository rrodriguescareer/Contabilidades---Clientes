export function validEmail(value:string){
 return value.length<=254&&/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}
export function validBirthDate(value:string,today=new Date().toISOString().slice(0,10)){
 if(!/^\d{4}-\d{2}-\d{2}$/.test(value)||value<'0001-01-01'||value>today)return false;
 const date=new Date(value+'T00:00:00.000Z');
 return Number.isFinite(date.getTime())&&date.toISOString().slice(0,10)===value;
}
export function personError(name:string,birth:string,nif:string,email='',today?:string){
 if(!name.trim()||name.length>200)return 'Indique o nome completo, até 200 caracteres.';
 if(!validBirthDate(birth,today))return 'Indique uma data de nascimento válida, que não seja futura.';
 if(!/^[1-9][0-9]{8}$/.test(nif))return 'Indique um NIF com nove algarismos.';
 if(email&&!validEmail(email))return 'Indique um email válido.';
 return null;
}
export function registrationError(fields:{name:string;birth:string;nif:string;email:string;phone:string;address:string;password:string},today?:string){
 const {name,birth,nif,email,phone,address,password}=fields;
 const person=personError(name,birth,nif,email,today);if(person)return person;
 if(!validEmail(email))return 'Indique um email válido.';
 const digits=phone.replace(/\D/g,'');
 if(phone.length>30||!/^\+?[0-9 ().-]+$/.test(phone)||digits.length<7||digits.length>15)return 'Indique um número de telemóvel válido, incluindo o indicativo se necessário.';
 if(!address.trim()||address.length>400)return 'Indique a morada, código postal e localidade, até 400 caracteres.';
 if(password.length<12||password.length>128)return 'Use uma palavra-passe entre 12 e 128 caracteres.';
 return null;
}
